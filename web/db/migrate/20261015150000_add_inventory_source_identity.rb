# frozen_string_literal: true

class AddInventorySourceIdentity < ActiveRecord::Migration[8.1]
  # SQLite must switch foreign_keys OFF before its rollback transaction.
  # Rails' outer DDL transaction would otherwise make that PRAGMA ineffective.
  disable_ddl_transaction!

  def up
    connection.transaction do
      add_column :orders, :source_lines_complete, :boolean, default: false, null: false
      add_column :orders, :source_financial_status, :string
      add_column :order_lines, :source_line_id, :string
      add_column :order_lines, :source_variant_id, :string
      add_index :order_lines, [:tenant_id, :order_id, :source_line_id], unique: true, name: 'idx_order_lines_source_identity'
      add_index :order_lines, [:tenant_id, :source_variant_id], name: 'idx_order_lines_source_variant'
    end
  end

  def down
    # SQLite rebuilds the parent orders table to remove columns. With foreign
    # keys enabled, DROP TABLE would cascade-delete its children.
    raise ActiveRecord::IrreversibleMigration, 'Run this SQLite rollback outside an existing transaction.' if connection.transaction_open?

    connection.disable_referential_integrity { remove_identity_columns }
  end

  private

  def remove_identity_columns
    connection.transaction do
      remove_index :order_lines, name: 'idx_order_lines_source_variant'
      remove_index :order_lines, name: 'idx_order_lines_source_identity'
      remove_column :order_lines, :source_variant_id
      remove_column :order_lines, :source_line_id
      remove_column :orders, :source_financial_status
      remove_column :orders, :source_lines_complete
    end
  end
end
