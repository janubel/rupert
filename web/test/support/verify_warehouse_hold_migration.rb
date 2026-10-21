# frozen_string_literal: true

require Rails.root.join('db/migrate/20261018220000_create_warehouse_stock_holds')
raise 'Test-only migration check' unless Rails.env.test?
raise 'Requires an empty synthetic warehouse database' unless WarehouseStockHold.unscoped.count.zero? && WarehouseCart.count.zero? && WarehousePaymentAttempt.unscoped.count.zero?
config = ActiveRecord::Base.connection_db_config
raise 'Unexpected test database' unless config.adapter == 'sqlite3' && File.basename(config.database).include?('test')
migration = CreateWarehouseStockHolds.new('CreateWarehouseStockHolds', 20261018220000)
migration.migrate(:down)
tenant = Tenant.create!(name: 'Synthetic migration tenant', subdomain: 'synthetic-hold-migration')
Current.tenant = tenant
share = WarehouseShare.create!(name: 'Synthetic migration vendor')
cases = []
%w[unknown paid legacy declined].each_with_index do |state, index|
  cart = WarehouseCart.create!(tenant_id: tenant.id, share: share, token: SecureRandom.hex(20), status: %w[paid legacy].include?(state) ? 'checked_out' : 'open')
  cart.items.create!(tenant_id: tenant.id, share_id: cart.share_id, variant_id: "migration-variant-#{state}", title: 'Synthetic migration item', quantity: index + 1, unit_cents: 1000, line_cents: (index + 1) * 1000)
  order = nil
  if %w[paid legacy].include?(state)
    order = Core::Order.create!(source: 'online', source_order_id: "wh-#{cart.id}", channel: 'warehouse', gross_cents: (index + 1) * 1000, occurred_at: Time.current)
    order.mark_paid!
  end
  unless state == 'legacy'
    WarehousePaymentAttempt.create!(warehouse_cart: cart, status: state, invoice_number: SecureRandom.hex(10), nonce_digest: SecureRandom.hex(32), gateway_fingerprint: SecureRandom.hex(32), amount_cents: (index + 1) * 1000, shipping_json: '{}', submitted_at: Time.current)
  end
  cases << [cart, state, order]
end
migration.migrate(:up)
WarehouseStockHold.reset_column_information
cases.each do |cart, state, order|
  holds = WarehouseStockHold.where(warehouse_cart_id: cart.id)
  if state == 'declined'
    raise 'Declined stock was incorrectly held' unless holds.empty?
  else
    hold = holds.sole
    raise 'Wrong legacy attribution' unless hold.tenant_id == tenant.id && hold.order_id == order&.id && hold.variant_id == "migration-variant-#{state}" && hold.status == 'held'
  end
end
puts 'HOLD_MIGRATION_BACKFILL_VERIFIED'
# Remove only this synthetic cohort; real production data is never loaded here.
WarehouseStockHold.where(tenant_id: tenant.id).delete_all
WarehousePaymentAttempt.where(tenant_id: tenant.id).delete_all
WarehouseCartItem.where(tenant_id: tenant.id).delete_all
WarehouseCart.where(tenant_id: tenant.id).delete_all
Core::Order.where(tenant_id: tenant.id).delete_all
share.delete
Tenant.where(id: tenant.id).delete_all
Current.reset
