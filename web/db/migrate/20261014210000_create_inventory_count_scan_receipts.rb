# frozen_string_literal: true

class CreateInventoryCountScanReceipts < ActiveRecord::Migration[8.1]
  def change
    create_table :inventory_count_scan_receipts, id: :string do |t|
      t.string :tenant_id, null: false
      t.string :count_id, null: false
      t.string :request_token, null: false
      t.string :fingerprint, null: false
      t.string :created_by, null: false
      t.text :result, null: false
      t.datetime :created_at, null: false
    end
    add_index :inventory_count_scan_receipts, %i[tenant_id count_id request_token],
      unique: true, name: 'idx_count_scan_receipts_request'
    add_foreign_key :inventory_count_scan_receipts, 'InventoryCount', column: :count_id, on_delete: :cascade
  end
end
