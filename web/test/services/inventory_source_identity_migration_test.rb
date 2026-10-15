# frozen_string_literal: true

require 'test_helper'
require_relative '../../db/migrate/20261015150000_add_inventory_source_identity'

class InventorySourceIdentityMigrationTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  class IsolatedDatabase < ActiveRecord::Base
    self.abstract_class = true
  end

  TABLES = %w[orders order_lines payments fulfillments refunds].freeze
  NEW_COLUMNS = %w[source_lines_complete source_financial_status source_line_id source_variant_id].freeze

  setup do
    # Always exercise SQLite in a separate in-memory pool, including on PG CI.
    # Never rebuild the application test database or its fixture tables.
    IsolatedDatabase.establish_connection(adapter: 'sqlite3', database: ':memory:')
    @pool = IsolatedDatabase.connection_pool
    @connection = @pool.lease_connection
    @connection.create_table(:orders) do |table|
      table.string :tenant_id
      table.string :source_order_id
      table.integer :gross_cents
    end
    %w[order_lines payments fulfillments refunds].each do |table|
      @connection.create_table(table) do |columns|
        columns.bigint :order_id, null: false
        columns.string :tenant_id
        columns.string :description
      end
      @connection.add_foreign_key(table, :orders, on_delete: :cascade)
    end
    @connection.execute("INSERT INTO orders (id, tenant_id, source_order_id, gross_cents) VALUES (1, 'isolated', 'sale-1', 1250), (2, 'isolated', 'sale-2', 3000)")
    %w[order_lines payments fulfillments refunds].each do |table|
      @connection.execute("INSERT INTO #{table} (id, order_id, tenant_id, description) VALUES (1, 1, 'isolated', 'preserve first'), (2, 2, 'isolated', 'preserve second')")
    end
    ActiveRecord::Tasks::DatabaseTasks.stubs(:migration_connection).returns(@connection)
    ActiveRecord::Tasks::DatabaseTasks.stubs(:migration_connection_pool).returns(@pool)
    @before = snapshot
  end

  teardown do
    @pool&.disconnect!
    IsolatedDatabase.remove_connection
  end

  test 'actual Rails migrator preserves parent and cascading children across up down and up' do
    assert AddInventorySourceIdentity.disable_ddl_transaction
    assert_equal 1, @connection.select_value('PRAGMA foreign_keys')

    run_migration(:up)
    assert_equal @before, snapshot
    assert @connection.index_exists?(:order_lines, name: 'idx_order_lines_source_identity')
    assert_equal [false, false], @connection.select_values('SELECT source_lines_complete FROM orders ORDER BY id').map { |value| value == 1 }

    run_migration(:down)
    assert_equal @before, snapshot
    assert_equal 1, @connection.select_value('PRAGMA foreign_keys')
    assert_empty @connection.execute('PRAGMA foreign_key_check')
    refute @connection.column_exists?(:orders, :source_lines_complete)
    refute @connection.column_exists?(:order_lines, :source_line_id)

    run_migration(:up)
    assert_equal @before, snapshot
    assert_equal 1, @connection.select_value('PRAGMA foreign_keys')
    assert_empty @connection.execute('PRAGMA foreign_key_check')
    assert @connection.index_exists?(:order_lines, name: 'idx_order_lines_source_identity')

    # The original cascade constraint still works after the complete cycle.
    @connection.execute('DELETE FROM orders WHERE id = 1')
    TABLES.each { |table| assert_equal 1, @connection.select_value("SELECT COUNT(*) FROM #{table}") }
  end

  test 'SQLite rollback fails before changing data when called inside an outer transaction' do
    run_migration(:up)
    migration = AddInventorySourceIdentity.new
    @connection.transaction do
      assert_raises(ActiveRecord::IrreversibleMigration) { migration.suppress_messages { migration.exec_migration(@connection, :down) } }
    end
    assert_equal @before, snapshot
    assert @connection.column_exists?(:orders, :source_lines_complete)
    assert @connection.index_exists?(:order_lines, name: 'idx_order_lines_source_identity')
    assert_equal 1, @connection.select_value('PRAGMA foreign_keys')
  end

  test 'failed SQLite rollback restores schema rows and foreign key enforcement' do
    run_migration(:up)
    migration = AddInventorySourceIdentity.new
    original = @connection.method(:remove_column)
    @connection.define_singleton_method(:remove_column) do |table, column, **options|
      raise StandardError, 'injected rollback failure' if table.to_s == 'orders' && column.to_s == 'source_financial_status'

      original.call(table, column, **options)
    end
    assert_raises(StandardError) { migration.suppress_messages { migration.exec_migration(@connection, :down) } }
    assert_equal @before, snapshot
    assert @connection.column_exists?(:order_lines, :source_line_id)
    assert @connection.index_exists?(:order_lines, name: 'idx_order_lines_source_identity')
    assert_equal 1, @connection.select_value('PRAGMA foreign_keys')
    assert_empty @connection.execute('PRAGMA foreign_key_check')
  end

  private

  def run_migration(direction)
    migration = AddInventorySourceIdentity.new('AddInventorySourceIdentity', 20261015150000)
    migration.suppress_messages do
      ActiveRecord::Migrator.new(direction, [migration], @pool.schema_migration, @pool.internal_metadata, 20261015150000).run
    end
  end

  def snapshot
    TABLES.to_h do |table|
      rows = @connection.select_all("SELECT * FROM #{table} ORDER BY id").to_a
        .map { |row| row.except(*NEW_COLUMNS) }
      [table, rows]
    end
  end
end
