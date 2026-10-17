# frozen_string_literal: true

class CreateWarehouseStockHolds < ActiveRecord::Migration[8.1]
  def up
    create_table :warehouse_stock_holds do |t|
      t.string :tenant_id, null: false
      t.references :warehouse_cart, null: false, foreign_key: true
      t.references :warehouse_payment_attempt, foreign_key: true
      t.references :order, foreign_key: true
      t.string :variant_id, null: false
      t.integer :quantity, null: false
      t.string :status, null: false, default: 'held'
      t.string :release_reason
      t.datetime :released_at
      t.references :released_by, foreign_key: { to_table: :users }
      t.datetime :fulfillment_confirmed_at
      t.datetime :source_adjusted_at
      t.datetime :source_refreshed_at
      t.text :source_adjustment_reference
      t.timestamps
    end
    add_index :warehouse_stock_holds, [:tenant_id, :status, :variant_id], name: 'idx_warehouse_holds_available'
    add_index :warehouse_stock_holds, [:warehouse_cart_id, :variant_id], unique: true,
      where: "status = 'held'", name: 'idx_warehouse_holds_one_active_line'
    add_check_constraint :warehouse_stock_holds, 'quantity > 0', name: 'warehouse_holds_positive_quantity'
    add_check_constraint :warehouse_stock_holds, "status IN ('held', 'released')", name: 'warehouse_holds_valid_status'

    # Preserve existing financial records. Older approved/uncertain attempts and
    # completed checkout carts also need holds until staff confirms source stock.
    execute <<~SQL
      INSERT INTO warehouse_stock_holds
        (tenant_id, warehouse_cart_id, warehouse_payment_attempt_id, order_id, variant_id, quantity, status, created_at, updated_at)
      SELECT c.tenant_id, c.id, a.id, o.id, i.variant_id, i.quantity, 'held', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      FROM warehouse_carts c
      JOIN warehouse_cart_items i ON i.cart_id = c.id AND i.tenant_id = c.tenant_id AND i.share_id = c.share_id
      LEFT JOIN warehouse_payment_attempts a ON a.warehouse_cart_id = c.id AND a.tenant_id = c.tenant_id
        AND a.status IN ('submitting', 'unknown', 'approved', 'paid')
        AND a.id = (SELECT MAX(prior.id) FROM warehouse_payment_attempts prior
          WHERE prior.warehouse_cart_id = c.id AND prior.tenant_id = c.tenant_id AND prior.status IN ('submitting', 'unknown', 'approved', 'paid'))
      LEFT JOIN orders o ON o.tenant_id = c.tenant_id AND o.source = 'online' AND o.channel = 'warehouse'
        AND o.source_order_id = 'wh-' || CAST(c.id AS TEXT)
      WHERE i.quantity > 0 AND (a.id IS NOT NULL OR (c.status = 'checked_out' AND o.id IS NOT NULL))
    SQL
  end

  def down
    drop_table :warehouse_stock_holds
  end
end
