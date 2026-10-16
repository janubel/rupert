# frozen_string_literal: true

require 'test_helper'

class InventoryLocationViewTest < ActionDispatch::IntegrationTest
  setup do
    Current.tenant = tenants(:default_tenant)
    @at = Time.current.change(usec: 0)
    product = ShopifyProduct.create!(id: 'view-product', title: 'Current tea', status: 'ACTIVE', catalog_present: true, catalog_read_at: @at)
    @variant = ShopifyVariant.create!(id: 'view-variant', product: product, title: '30 count', sku: 'TEA-30', tracked: true,
      catalog_present: true, catalog_read_at: @at, inventoryQuantity: 3)
    online = Location.create!(source: 'shopify', externalId: 'view-online', name: 'Online stock')
    retail = Location.create!(source: 'ctrax', externalId: 'fixture/view', name: 'Retail stock')
    ShopifyStockSnapshot.create!(location: online, shop_domain: 'fixture.myshopify.com', captured_at: @at,
      records_json: [{ 'id' => @variant.id, 'on_hand' => 5, 'available' => 3, 'committed' => 2 }])
    CtraxStockSnapshot.create!(location: retail, api_origin: 'https://fixture.api.cannatrax.net', store_id: '1', captured_at: @at,
      records_json: [{ 'id' => 'view-native', 'name' => 'Retail tea', 'sku' => 'TEA-30', 'quantity' => '-3', 'manage_stock' => true }])
    Location.create!(source: 'square', externalId: 'old-square', name: 'OLD-SQUARE-STOCK')
    post login_path, params: { email: 'admin@example.com', password: 'password' }
  end

  teardown { Current.reset }

  test 'inventory entry point opens the shared read-only comparison and preserves search' do
    get inventory_index_path, params: { q: 'Tea' }
    assert_response :success
    assert_select 'h1', 'Shopify & C-Trax stock'
    assert_includes response.body, 'Online stock'
    assert_includes response.body, 'Retail stock'
    assert_not_includes response.body, 'OLD-SQUARE-STOCK'
    assert_select 'th', text: 'Committed'
    assert_select 'td', text: '-3'
    assert_select 'td', text: '-8'
    assert_select 'form[action=?][method=post]', stock_comparison_path, count: 0
  end

  test 'view and CSV do not contact providers or write counts' do
    ShopifyClient.expects(:graphql).never
    Ctrax::StockSync.expects(:call).never
    InventoryWriter.expects(:adjust_shopify!).never
    InventoryWriter.expects(:physical_count!).never
    get stock_comparison_path
    assert_response :success
    assert_equal 'no-store', response.headers['Cache-Control']
    get stock_comparison_path(format: :csv)
    assert_response :success
    assert_equal 'text/csv', response.media_type
    assert_includes response.body, 'Shopify on hand'
    assert_includes response.body, 'SKU candidate'
    assert_equal 3, @variant.reload.inventoryQuantity
    assert_equal '-3', CtraxStockSnapshot.first.records.first['quantity']
  end

  test 'search and attention filters apply consistently to HTML and CSV' do
    get stock_comparison_path, params: { q: 'absent item', filter: 'attention' }
    assert_response :success
    assert_includes response.body, 'No current records match'
    get stock_comparison_path(format: :csv), params: { q: 'absent item', filter: 'attention' }
    assert_equal 1, CSV.parse(response.body).size
  end

  test 'workspace selection and permissions are enforced for both formats' do
    other = Tenant.create!(name: 'Private other', subdomain: 'private-stock-view')
    location = Location.unscoped.create!(tenant_id: other.id, source: 'ctrax', externalId: 'private/1', name: 'PRIVATE-STOCK')
    get stock_comparison_path, params: { ctrax_location_id: location.id }
    assert_response :not_found
    get stock_comparison_path
    assert_response :success
    assert_not_includes response.body, 'PRIVATE-STOCK'
    users(:regular_user).update_permission_overrides!(%w[settings.read])
    get stock_comparison_path(format: :csv)
    assert_redirected_to root_path
  end
end
