# frozen_string_literal: true

# Synthetic C-Trax business days shaped like Ctrax::SalesSync snapshots: one
# native line per unit with price/tax in minor units, order-level discounts and
# a refund count only. Store "Downtown" has a current stock read; "Uptown" has
# none, so its sold variants carry no SKU/barcode/category.
module CtraxDailyItemsFixture
  ORIGIN = 'https://fixture.api.cannatrax.net'

  def build_ctrax_items_fixture
    @date = Date.new(2026, 10, 14)
    @downtown = Location.create!(source: 'ctrax', externalId: 'fixture.api.cannatrax.net/7', name: 'Downtown')
    @uptown = Location.create!(source: 'ctrax', externalId: 'fixture.api.cannatrax.net/8', name: 'Uptown')
    CtraxStockSnapshot.create!(location: @downtown, api_origin: ORIGIN, store_id: '7', captured_at: Time.current, records_json: [
      { 'id' => '101', 'sku' => 'HH-GUM-10', 'barcode' => nil, 'name' => 'Gummies Mango 10 count', 'product_name' => 'Gummies Mango',
        'category' => 'Edibles', 'price_cents' => 2500, 'quantity' => '12', 'manage_stock' => true, 'listed' => true },
      { 'id' => '102', 'sku' => nil, 'barcode' => nil, 'name' => 'Blue Dream Flower 3.5 g', 'product_name' => 'Blue Dream Flower',
        'category' => 'Flower', 'price_cents' => 4000, 'quantity' => '4', 'manage_stock' => true, 'listed' => true },
      { 'id' => '103', 'sku' => 'PRE-ROLL-1', 'barcode' => nil, 'name' => 'House Pre-Roll 1 g', 'product_name' => 'House Pre-Roll',
        'category' => 'Pre-rolls', 'price_cents' => 1500, 'quantity' => '30', 'manage_stock' => true, 'listed' => true }
    ])
    gummies = ShopifyProduct.create!(id: 'items-gummies', title: 'Gummies Mango', status: 'ACTIVE', catalog_present: true, catalog_read_at: Time.current)
    ShopifyVariant.create!(id: 'gid://shopify/ProductVariant/9101', product: gummies, title: '10 count', sku: 'HH-GUM-10', price: 25,
      tracked: true, catalog_present: true, catalog_read_at: Time.current)
    flower = ShopifyProduct.create!(id: 'items-flower', title: 'Blue Dream Flower', status: 'ACTIVE', catalog_present: true, catalog_read_at: Time.current)
    ShopifyVariant.create!(id: 'gid://shopify/ProductVariant/9102', product: flower, title: '3.5 g', sku: 'BD-35', price: 40,
      tracked: true, catalog_present: true, catalog_read_at: Time.current)

    @downtown_day = ctrax_items_day(@downtown, '7', [
      ctrax_items_order('501', [ctrax_items_line('9001', '101', 2500, 150), ctrax_items_line('9002', '101', 2500, 150), ctrax_items_line('9003', '102', 4000, 240)],
        subtotal: 9000, tax: 540, total: 9540, tip: 100),
      ctrax_items_order('502', [ctrax_items_line('9004', '103', 1500, 60), ctrax_items_line('9005', '102', 4000, 210)],
        subtotal: 5500, discount: 500, tax: 270, total: 5270, type: 'credit', surcharge: 158),
      ctrax_items_order('503', [ctrax_items_line('9006', '104', 800, 48, name: 'Hemp Wick', variant: 'Roll')],
        subtotal: 800, tax: 48, total: 848, refund_count: 1),
      ctrax_items_order('504', [ctrax_items_line('9007', '101', 2500, 150)], subtotal: 2500, tax: 150, total: 2650).merge('status' => 'pending'),
      ctrax_items_order('505', [ctrax_items_line('9008', '101', 2500, 150)], subtotal: 2500, tax: 150, total: 2650).merge('deleted' => true)
    ])
    @uptown_day = ctrax_items_day(@uptown, '8', [
      ctrax_items_order('601', [ctrax_items_line('9101', '101', 2500, 150)], subtotal: 2500, tax: 150, total: 2650)
    ])
  end

  def ctrax_items_line(id, variant_id, price, tax, name: nil, variant: nil)
    names = { '101' => ['Gummies Mango', '10 count'], '102' => ['Blue Dream Flower', '3.5 g'], '103' => ['House Pre-Roll', '1 g'] }
    product, variant_name = names.fetch(variant_id, [name, variant])
    { 'id' => id, 'variant_id' => variant_id, 'name' => product, 'variant_name' => variant_name, 'price' => price, 'tax' => tax }
  end

  def ctrax_items_order(id, lines, subtotal:, tax:, total:, discount: 0, tip: 0, refund_count: 0, type: 'cash', surcharge: 0)
    { 'id' => id, 'receipt' => "FIXTURE-#{id}", 'register_session_id' => '9', 'status' => 'completed', 'deleted' => false,
      'completed_at' => "#{@date}T15:00:00-04:00", 'updated_at' => "#{@date}T15:00:00-04:00", 'lines' => lines, 'refund_count' => refund_count,
      'total' => total, 'subtotal' => subtotal, 'tax' => tax, 'discount' => discount, 'tip' => tip, 'shipping_amount' => 0, 'shipping_tax_amount' => 0,
      'payments' => [{ 'id' => "p#{id}", 'type' => type, 'status' => 'completed', 'deleted' => false, 'amount' => total,
                       'total_amount' => total + tip + surcharge, 'tip_amount' => tip, 'surcharge_amount' => surcharge,
                       'tendered_amount' => nil, 'change_back_amount' => nil }] }
  end

  def ctrax_items_day(location, store_id, orders)
    CtraxDay.create!(location: location, business_date: @date, api_origin: ORIGIN, store_id: store_id, currency: 'USD',
      timezone: 'America/New_York', source_digest: "items-#{store_id}", captured_at: Time.current, orders_json: orders,
      sessions_json: [], controls_json: { 'refunds_totals_sum' => store_id == '7' ? 848 : 0 })
  end
end
