# frozen_string_literal: true

class CreateWarehousePaymentAttempts < ActiveRecord::Migration[8.1]
  def change
    create_table :warehouse_payment_attempts do |t|
      t.string :tenant_id, null: false
      t.references :warehouse_cart, null: false, foreign_key: true
      t.string :status, null: false, default: 'submitting'
      t.string :invoice_number, null: false
      t.string :nonce_digest, null: false
      t.string :gateway_fingerprint, null: false
      t.integer :amount_cents, null: false
      t.text :shipping_json, null: false
      t.string :transaction_id
      t.datetime :submitted_at, null: false
      t.datetime :resolved_at
      t.timestamps
    end
    add_index :warehouse_payment_attempts, :nonce_digest, unique: true
    add_index :warehouse_payment_attempts, :invoice_number, unique: true
    add_index :warehouse_payment_attempts, :warehouse_cart_id, unique: true,
      where: "status IN ('submitting', 'unknown', 'approved')", name: 'idx_warehouse_attempts_one_unresolved'
    add_index :warehouse_payment_attempts, [:tenant_id, :warehouse_cart_id], name: 'idx_warehouse_attempts_tenant_cart'
  end
end
