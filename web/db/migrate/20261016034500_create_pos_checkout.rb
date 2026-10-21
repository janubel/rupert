# frozen_string_literal: true

class CreatePosCheckout < ActiveRecord::Migration[8.0]
  def change
    create_table :pos_settings do |t|
      t.string :tenant_id, null: false
      t.string :location_id, null: false
      t.boolean :cash_enabled, null: false, default: false
      t.boolean :stock_writes_enabled, null: false, default: false
      t.boolean :card_enabled, null: false, default: false
      t.string :environment, null: false, default: 'sandbox'
      t.string :gateway_id
      t.text :credentials_json, null: false, default: '{}'
      t.string :public_client_key
      t.datetime :verified_at
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    add_index :pos_settings, %i[tenant_id location_id], unique: true
    add_foreign_key :pos_settings, :tenants
    add_foreign_key :pos_settings, 'Location', column: :location_id
    create_table :pos_checkouts do |t|
      t.string :tenant_id, null: false
      t.string :location_id, null: false
      t.references :user, null: false, foreign_key: true
      # The display-session table is created by the later reconciliation migration.
      t.references :pos_display_session, null: false
      t.references :pos_session, foreign_key: true
      t.integer :cart_revision, null: false
      t.string :reference, null: false
      t.string :status, null: false, default: 'ready'
      t.string :tender, null: false
      t.boolean :demo, null: false, default: false
      t.text :lines_json, null: false
      t.integer :subtotal_cents, null: false
      t.integer :tax_cents, null: false
      t.integer :tip_cents, null: false
      t.integer :total_cents, null: false
      t.integer :cash_received_cents
      t.integer :change_cents
      t.references :order, foreign_key: true
      t.datetime :paid_at
      t.string :gateway_id
      t.string :environment
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    add_index :pos_checkouts, %i[tenant_id pos_display_session_id cart_revision], unique: true, name: 'idx_pos_checkout_revision'
    add_index :pos_checkouts, :reference, unique: true
    add_foreign_key :pos_checkouts, :tenants
    add_foreign_key :pos_checkouts, 'Location', column: :location_id
    create_table :pos_stock_allocations do |t|
      t.string :tenant_id, null: false
      t.string :location_id, null: false
      t.references :pos_checkout, null: false, foreign_key: true
      t.string :variant_id, null: false
      t.integer :quantity, null: false
      t.string :status, null: false, default: 'held'
      t.string :source_adjustment_id
      t.datetime :submitted_at
      t.datetime :applied_at
      t.timestamps
    end
    add_index :pos_stock_allocations, %i[tenant_id location_id variant_id], name: 'idx_pos_stock_pool'
    add_index :pos_stock_allocations, %i[pos_checkout_id variant_id], unique: true
    add_foreign_key :pos_stock_allocations, :tenants
    add_foreign_key :pos_stock_allocations, 'Location', column: :location_id
    create_table :pos_payment_attempts do |t|
      t.string :tenant_id, null: false
      t.references :pos_checkout, null: false, foreign_key: true
      t.string :invoice, null: false
      t.string :nonce_digest, null: false
      t.string :status, null: false, default: 'submitting'
      t.string :transaction_id
      t.datetime :submitted_at, null: false
      t.datetime :resolved_at
      t.timestamps
    end
    add_index :pos_payment_attempts, :invoice, unique: true
    add_index :pos_payment_attempts, %i[tenant_id nonce_digest], unique: true
    add_foreign_key :pos_payment_attempts, :tenants
    add_column :orders, :tip_cents, :integer, null: false, default: 0
  end
end
