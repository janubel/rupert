# frozen_string_literal: true

require 'test_helper'

class BulkLedgerConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @tenant = Tenant.create!(name: 'Concurrent bulk', subdomain: "concurrent-bulk-#{SecureRandom.hex(4)}")
    Current.tenant = @tenant
    @material = BulkMaterial.create!(name: 'Concurrent material', unit: 'g')
    @lot = BulkLedger.receive(material: @material, attributes: { code: 'RACE' },
      movement_attributes: { quantity: '5', unit: 'g', reference: 'Supplier' }, actor: 'counter@example.com')
  end

  teardown do
    Current.tenant = @tenant
    BulkMovement.delete_all
    BulkLot.delete_all
    @material&.destroy!
    @tenant&.destroy!
    Current.reset
  end

  test 'separate connections cannot consume the same remaining bulk material twice' do
    movements = race do |number|
      BulkLedger.record(lot: BulkLot.find(@lot.id), attributes: { kind: 'consume', quantity: '4', unit: 'g',
        reference: "Use #{number}" }, actor: 'counter@example.com')
    end
    assert_equal 1, movements.count(&:persisted?)
    assert_equal 1000, @lot.reload.balance_mg
    assert_equal 2, BulkMovement.count
    assert_match(/negative/, movements.find { |movement| !movement.persisted? }.errors.full_messages.to_sentence)
  end

  test 'simultaneous initial receipt retries make one lot and one receipt' do
    token = SecureRandom.uuid
    lots = race do
      BulkLedger.receive(material: BulkMaterial.find(@material.id), attributes: { code: 'REPLAY', receipt_token: token },
        movement_attributes: { quantity: '1', unit: 'oz', reference: 'Same delivery' }, actor: 'counter@example.com')
    end
    assert lots.all?(&:persisted?)
    assert_equal 1, lots.map(&:id).uniq.size
    assert_equal 28_350, lots.first.balance_mg
    assert_equal 2, BulkLot.count
    assert_equal 2, BulkMovement.count
  end

  private

  def race(&operation)
    ready = Queue.new
    start = Queue.new
    results = Queue.new
    threads = Array.new(2) do |number|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          Current.tenant = @tenant
          ready << true
          start.pop
          results << operation.call(number)
        ensure
          Current.reset
        end
      rescue StandardError => e
        results << e
      end
    end
    2.times { ready.pop }
    2.times { start << true }
    threads.each { |thread| assert thread.join(15), 'concurrent bulk operation timed out' }
    Array.new(2) { results.pop }.tap do |records|
      records.each { |record| refute_kind_of Exception, record, record.inspect }
    end
  ensure
    threads&.each { |thread| thread.kill if thread.alive? }
  end
end
