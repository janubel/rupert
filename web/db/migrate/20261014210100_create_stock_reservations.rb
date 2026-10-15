# frozen_string_literal: true

class CreateStockReservations < ActiveRecord::Migration[8.1]
  def change
    create_table :stock_reservation_pools do |t|
      t.string :tenant_id, null: false
      t.string :source, null: false
      t.string :location_id, null: false
      t.string :source_item_id, null: false
      t.string :location_name, null: false
      t.string :item_label, null: false
      t.integer :lock_version, null: false, default: 0
    end
    add_index :stock_reservation_pools, %i[tenant_id source location_id source_item_id],
      unique: true, name: 'idx_reservation_pool_identity'

    create_table :stock_reservations do |t|
      t.string :tenant_id, null: false
      t.references :stock_reservation_pool, null: false, foreign_key: true, index: false
      t.integer :quantity, null: false
      t.string :reference, null: false
      t.string :request_token, null: false
      t.string :status, null: false, default: 'active'
      t.datetime :expires_at
      t.string :created_by, null: false
      t.string :released_by
      t.datetime :released_at
      t.timestamps
    end
    add_index :stock_reservations, %i[tenant_id request_token], unique: true, name: 'idx_reservations_request_token'
    add_index :stock_reservations, %i[tenant_id created_at id], name: 'idx_reservations_tenant_created'
    add_index :stock_reservations, %i[stock_reservation_pool_id status expires_at], name: 'idx_reservations_pool_active'
    add_check_constraint :stock_reservations, 'quantity > 0', name: 'stock_reservations_positive_quantity'
    add_check_constraint :stock_reservations, "status IN ('active', 'released')", name: 'stock_reservations_status'
    add_check_constraint :stock_reservation_pools, "source IN ('shopify', 'square')", name: 'stock_reservation_pools_source'
  end
end
