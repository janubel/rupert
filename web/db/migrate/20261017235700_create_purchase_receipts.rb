# frozen_string_literal: true

class CreatePurchaseReceipts < ActiveRecord::Migration[8.1]
  def change
    create_table :purchase_receipts do |t|
      t.string :tenant_id, null: false
      t.references :submitted_by, null: false, foreign_key: { to_table: :users }
      t.string :status, null: false, default: 'draft'
      t.string :payee, null: false
      t.date :incurred_on, null: false
      t.integer :amount_cents, null: false
      t.string :currency, null: false, default: 'USD'
      t.string :category, null: false
      t.text :notes
      t.string :filename, null: false
      t.string :content_type, null: false
      t.integer :byte_size, null: false
      t.string :sha256, null: false
      t.text :content_base64, null: false
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    add_foreign_key :purchase_receipts, :tenants
    add_index :purchase_receipts, [:tenant_id, :status, :created_at]
    add_index :purchase_receipts, [:tenant_id, :submitted_by_id, :sha256], unique: true, name: 'idx_purchase_receipts_duplicate_file'
    create_table :purchase_receipt_events do |t|
      t.string :tenant_id, null: false
      t.references :purchase_receipt, null: false, foreign_key: true
      t.references :actor, null: false, foreign_key: { to_table: :users }
      t.string :action, null: false
      t.text :snapshot_json, null: false
      t.text :note
      t.timestamps
    end
    add_foreign_key :purchase_receipt_events, :tenants
  end
end
