# frozen_string_literal: true

require 'test_helper'

# Product pairing: people confirm or reject that a Shopify variant and a C-Trax item are the same product.
class ProductPairsTest < ActionDispatch::IntegrationTest
  setup do
    Current.tenant = tenants(:default_tenant)
    @admin = users(:regular_user)
    post login_path, params: { email: @admin.email, password: 'password' }
    @at = Time.current.change(usec: 0)
    product = ShopifyProduct.create!(id: 'pair-product', title: 'Tea', status: 'ACTIVE', catalog_present: true, catalog_read_at: @at)
    @by_sku = ShopifyVariant.create!(id: 'gid://shopify/ProductVariant/pair-1', product: product, title: '30 count', sku: '77001',
      tracked: true, catalog_present: true, catalog_read_at: @at)
    @no_sku = ShopifyVariant.create!(id: 'gid://shopify/ProductVariant/pair-2', product: product, title: 'Sampler', sku: nil,
      tracked: true, catalog_present: true, catalog_read_at: @at)
    @online = Location.create!(source: 'shopify', externalId: 'pair-online', name: 'Online')
    @retail = Location.create!(source: 'ctrax', externalId: 'pair/1', name: 'Retail')
    ShopifyStockSnapshot.create!(location: @online, shop_domain: 'fixture.myshopify.com', captured_at: @at,
      records_json: [{ 'id' => @by_sku.id, 'available' => 5, 'on_hand' => 5, 'committed' => 0 }, { 'id' => @no_sku.id, 'available' => 2, 'on_hand' => 2, 'committed' => 0 }])
    CtraxStockSnapshot.create!(location: @retail, api_origin: 'https://fixture.api.cannatrax.net', store_id: '1', captured_at: @at,
      records_json: [{ 'id' => 'ct-1', 'sku' => '77001', 'name' => 'Tea 30 count', 'quantity' => '5', 'manage_stock' => true },
        { 'id' => 'ct-9', 'name' => 'Tea sampler box', 'quantity' => '2', 'manage_stock' => true }])
    @where = { shopify_location_id: @online.id, ctrax_location_id: @retail.id }
  end

  teardown { Current.reset }

  def comparison = StockComparison.new(**@where)
  def row(variant) = comparison.rows.find { |candidate| candidate[:shopify_id] == variant.id }

  test 'coverage counts exact and confirmed pairs; confirming a pair makes its stock comparable' do
    assert_equal [1, 2], comparison.summary.values_at(:ctrax_certain, :ctrax_items)
    get stock_comparison_path(@where)
    assert_select '[data-pairing-coverage]', /C-Trax items paired: 1 of 2 \(50%\)/

    post stock_comparison_pairs_path, params: @where.merge(shopify_variant_id: @no_sku.id, ctrax_record_id: 'ct-9', decision: 'paired')
    assert_redirected_to stock_comparison_path(@where)
    pair = ProductPair.sole
    assert_equal ['paired', @admin.id], [pair.decision, pair.decided_by_id]
    sampler = row(@no_sku)
    assert_equal ['Confirmed pair', 'ct-9', true], sampler.values_at(:identity, :ctrax_id, :confirmed)
    assert_equal 0, sampler[:difference], 'confirmed pairs get a quantity difference'
    assert_equal [2, 2, 1], comparison.summary.values_at(:ctrax_certain, :ctrax_items, :confirmed)
    get stock_comparison_path(@where)
    assert_select '[data-pair-actions] button', 'Undo pair'
  end

  test 'not the same stops the suggestion from coming back, and undo restores it' do
    assert_equal 'ct-1', row(@by_sku)[:ctrax_id]
    post stock_comparison_pairs_path, params: @where.merge(shopify_variant_id: @by_sku.id, ctrax_record_id: 'ct-1', decision: 'not_same')
    assert_equal 'Marked not the same product', row(@by_sku)[:identity]
    assert_nil row(@by_sku)[:ctrax_id]
    delete stock_comparison_pairs_path, params: @where.merge(shopify_variant_id: @by_sku.id, ctrax_record_id: 'ct-1')
    assert_empty ProductPair.all
    assert_equal 'ct-1', row(@by_sku)[:ctrax_id]
  end

  test 'an item pairs with only one other item, and a change since confirming is flagged' do
    post stock_comparison_pairs_path, params: @where.merge(shopify_variant_id: @no_sku.id, ctrax_record_id: 'ct-9', decision: 'paired')
    post stock_comparison_pairs_path, params: @where.merge(shopify_variant_id: @by_sku.id, ctrax_record_id: 'ct-9', decision: 'paired')
    assert_match(/already paired/, flash[:alert])
    assert_equal 1, ProductPair.count
    @no_sku.update!(title: 'Sampler (new box)')
    assert_includes row(@no_sku)[:issues], 'Changed since it was confirmed; check the pair again'
  end

  test 'pairing needs inventory write permission' do
    delete logout_path
    reader = User.create!(tenant: tenants(:default_tenant), email: 'pairs-reader@example.com', name: 'Reader', role: 'reader', password: 'password123')
    post login_path, params: { email: reader.email, password: 'password123' }
    post stock_comparison_pairs_path, params: @where.merge(shopify_variant_id: @no_sku.id, ctrax_record_id: 'ct-9', decision: 'paired')
    assert_empty ProductPair.all
  end
end
