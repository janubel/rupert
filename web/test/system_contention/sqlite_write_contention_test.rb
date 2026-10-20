# frozen_string_literal: true

require 'test_helper'

# Web requests and the job worker write to the same SQLite file. With WAL and
# a busy timeout, concurrent writers must queue, never fail with SQLITE_BUSY,
# and never lose a committed row. This drives several threads, each on its
# own connection (like Puma threads and the Solid Queue worker), through
# interleaved short write transactions.
class SqliteWriteContentionTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  # One connection per writer, leaving a spare in the pool (RAILS_MAX_THREADS, default 5).
  WRITERS = [ActiveRecord::Base.connection_pool.size - 1, 2].max
  ROWS_PER_WRITER = 25

  setup do
    skip 'SQLite only' unless ActiveRecord::Base.connection.adapter_name.casecmp?('sqlite')
    @tenant = tenants(:default_tenant)
    WebhookDelivery.where(provider: 'contention-test').delete_all
  end

  teardown do
    WebhookDelivery.where(provider: 'contention-test').delete_all
  end

  test 'the configured pragmas are in effect on every connection' do
    conn = ActiveRecord::Base.connection
    assert_equal 'wal', conn.select_value('PRAGMA journal_mode')
    assert_equal 1, conn.select_value('PRAGMA foreign_keys').to_i
    assert_equal 1, conn.select_value('PRAGMA synchronous').to_i, 'NORMAL'
    # Rails installs the busy wait as a Ruby-level handler, so PRAGMA busy_timeout reads 0; check the configured value.
    assert_operator conn.pool.db_config.configuration_hash[:timeout].to_i, :>=, 5000
    assert_equal 67_108_864, conn.select_value('PRAGMA journal_size_limit').to_i
  end

  test 'parallel writers on separate connections queue behind the busy timeout and lose nothing' do
    errors = Queue.new
    started = Concurrent::CountDownLatch.new(WRITERS)
    threads = WRITERS.times.map do |writer|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          started.count_down
          started.wait(5)
          ROWS_PER_WRITER.times do |i|
            ActiveRecord::Base.transaction do
              WebhookDelivery.create!(provider: 'contention-test', delivery_id: "w#{writer}-#{i}", topic: 'test', received_at: Time.current)
              # Hold the write lock briefly so the others really contend.
              WebhookDelivery.where(provider: 'contention-test', delivery_id: "w#{writer}-#{i}").update_all(status: 'processed')
            end
          end
        end
      rescue StandardError => e
        errors << e
      end
    end
    threads.each { |t| t.join(60) }

    assert_empty errors.size.times.map { errors.pop }.map { |e| "#{e.class}: #{e.message}" }
    assert_equal WRITERS * ROWS_PER_WRITER, WebhookDelivery.where(provider: 'contention-test').count
    assert_equal WRITERS * ROWS_PER_WRITER, WebhookDelivery.where(provider: 'contention-test', status: 'processed').count
  end
end
