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

  test 'comparison entry point opens the shared read-only comparison and preserves search' do
    get stock_comparison_path, params: { q: 'Tea' }
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

  test 'name package review shows both source names and evidence without a quantity delta' do
    @variant.product.update!(title: 'Chamomile Tea Indoor')
    @variant.update!(title: '30 Count', sku: nil)
    CtraxStockSnapshot.first.update!(records_json: [{ 'id' => 'tea-name-review', 'name' => 'Tea Chamomile 30ct', 'quantity' => '2', 'manage_stock' => true }])
    get stock_comparison_path, params: { filter: 'candidates', q: 'Tea Chamomile' }
    assert_response :success
    assert_includes response.body, 'Name/package candidate'
    assert_includes response.body, 'Tea Chamomile 30ct'
    assert_includes response.body, 'Matching evidence'
    assert_includes response.body, 'quantity difference withheld'
    get stock_comparison_path(format: :csv), params: { filter: 'candidates', q: 'Tea Chamomile' }
    csv = CSV.parse(response.body)
    assert_equal 2, csv.size
    assert_nil csv.last[11]
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

  test 'saved source findings are searchable escaped and exported without provider or stock writes' do
    @variant.update!(sku: nil)
    note = '=HYPERLINK("https://invalid.example") <script>private source-copy finding</script>'
    StockIdentityFindings.publish!(shopify: ShopifyStockSnapshot.first, ctrax: CtraxStockSnapshot.first, reviewed_at: @at.iso8601,
      notes: [{ 'shopify_id' => @variant.id, 'ctrax_id' => 'view-native', 'severity' => 'warning', 'text' => note }],
      candidates: [{ 'shopify_id' => @variant.id, 'ctrax_id' => 'view-native', 'kind' => 'family', 'evidence' => 'Source description supports this product family; package unverified' }])
    ShopifyClient.expects(:graphql).never
    Ctrax::StockSync.expects(:call).never
    InventoryWriter.expects(:adjust_shopify!).never
    get stock_comparison_path, params: { filter: 'findings', q: 'private source-copy' }
    assert_response :success
    assert_includes response.body, 'Saved stock investigation'
    assert_includes response.body, 'Investigated family candidate'
    assert_includes response.body, 'Investigation findings'
    assert_select 'script', text: 'private source-copy finding', count: 0
    get stock_comparison_path(format: :csv), params: { filter: 'findings', q: 'private source-copy' }
    csv = CSV.parse(response.body)
    assert_equal 2, csv.size
    assert_nil csv.last[11]
    assert_equal "'#{note}", csv.last[csv.first.index('Investigation findings')]
    assert_equal 3, @variant.reload.inventoryQuantity
    assert_nil @variant.sku
    assert_equal '-3', CtraxStockSnapshot.first.records.first['quantity']
  end
end
