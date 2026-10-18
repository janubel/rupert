# frozen_string_literal: true

class CreateStockRequests < ActiveRecord::Migration[8.1]
  def change
    create_table :stock_requests do |t|
      t.string :tenant_id, null: false
      t.string :request_kind, null: false
      t.references :source_pool, null: false, foreign_key: { to_table: :stock_reservation_pools }
      t.references :destination_pool, foreign_key: { to_table: :stock_reservation_pools }
      t.references :stock_reservation, foreign_key: true, index: { unique: true }
      t.integer :quantity, null: false
      t.integer :received_quantity, null: false, default: 0
      t.string :reference, null: false
      t.date :due_on
      t.string :status, null: false, default: 'pending'
      t.string :created_by, null: false
      t.string :source_location_external_id, null: false
      t.string :destination_location_external_id
      t.timestamps
    end
    add_index :stock_requests, [:tenant_id, :request_kind, :status, :id], name: 'idx_stock_requests_queue'
    add_check_constraint :stock_requests, 'quantity > 0 AND received_quantity >= 0 AND received_quantity <= quantity', name: 'stock_requests_quantities'
    add_check_constraint :stock_requests, "request_kind IN ('transfer', 'backorder')", name: 'stock_requests_kind'
    add_check_constraint :stock_requests, "status IN ('pending', 'allocated', 'dispatched', 'completed', 'cancelled')", name: 'stock_requests_status'
    add_check_constraint :stock_requests, "(request_kind = 'transfer' AND destination_pool_id IS NOT NULL AND source_pool_id <> destination_pool_id) OR (request_kind = 'backorder' AND destination_pool_id IS NULL)", name: 'stock_requests_destination'

    create_table :stock_request_events do |t|
      t.string :tenant_id, null: false
      t.references :stock_request, null: false, foreign_key: true
      t.string :action, null: false
      t.string :request_token, null: false
      t.string :payload_digest, null: false
      t.string :actor, null: false
      t.integer :quantity, null: false, default: 0
      t.text :reference
      t.datetime :source_adjusted_at
      t.datetime :source_refreshed_at
      t.timestamps
    end
    add_index :stock_request_events, [:tenant_id, :request_token], unique: true

    create_table :purchase_deliveries do |t|
      t.string :tenant_id, null: false
      t.references :purchase_order, null: false, foreign_key: true
      t.string :request_token, null: false
      t.string :payload_digest, null: false
      t.string :actor, null: false
      t.text :quantities_json, null: false
      t.timestamps
    end
    add_index :purchase_deliveries, [:tenant_id, :request_token], unique: true
  end
end
