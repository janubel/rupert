# frozen_string_literal: true

require 'test_helper'

class ShopifyCatalogFreshnessTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
    @product = ShopifyProduct.create!(id: 'fresh-product', title: 'Tea', status: 'ACTIVE', catalog_present: true)
    @old = ShopifyVariant.create!(id: 'old-variant', productId: @product.id, title: 'Old pack', inventoryQuantity: 19, catalog_present: true)
    @location = Location.create!(source: 'shopify', externalId: 'source-location', name: 'Online')
    @level = InventoryLevel.create!(source: 'shopify', locationId: @location.id, shopifyVariantId: @old.id, quantity: 19)
    @nodes = [{ 'id' => @product.id, 'title' => 'Tea', 'status' => 'ARCHIVED', 'variants' => page([variant('new-variant')]) }]
    @stock_values = [{ 'name' => 'available', 'quantity' => 3 }, { 'name' => 'on_hand', 'quantity' => 5 }, { 'name' => 'committed', 'quantity' => 2 }]
  end

  teardown { Current.reset }

  test 'complete all-status catalog refresh preserves history and does not clear stock' do
    stub_reads
    ShopifyClient.expects(:graphql).with { |q, _| q.include?('mutation') }.never
    CatalogSyncer.sync!
    assert_equal 'ARCHIVED', @product.reload.status
    assert @product.catalog_present
    refute @old.reload.catalog_present
    assert_equal 19, @old.inventoryQuantity
    assert_equal 19, @level.reload.quantity
    assert ShopifyVariant.find('new-variant').catalog_present
    assert_empty ShopifyVariant.current_catalog
  end

  test 'signed stock states and barcode publish atomically with the catalog epoch' do
    @nodes.first['status'] = 'ACTIVE'
    @stock_values[0]['quantity'] = -2
    stub_reads
    CatalogSyncer.sync!
    snapshot = ShopifyStockSnapshot.find_by!(location_id: @location.id)
    assert_equal(-2, snapshot.records.first['available'])
    assert_equal 5, snapshot.records.first['on_hand']
    assert_equal 2, snapshot.records.first['committed']
    fresh = ShopifyVariant.find('new-variant')
    assert_equal 'fresh-barcode', fresh.barcode
    assert_equal snapshot.captured_at, fresh.catalog_read_at
    assert_equal ['new-variant'], ShopifyVariant.current_catalog.pluck(:id)
  end

  test 'a native unlisted product does not block a complete catalog read' do
    @nodes.first['status'] = 'UNLISTED'
    stub_reads
    CatalogSyncer.sync!
    assert_equal 'UNLISTED', @product.reload.status
    assert @product.catalog_present
    refute @old.reload.catalog_present
    assert_equal 19, @old.inventoryQuantity
    assert_empty ShopifyVariant.current_catalog
  end

  test 'incomplete pagination never retires the previous catalog' do
    @nodes.first['variants']['pageInfo'] = { 'hasNextPage' => true, 'endCursor' => nil }
    stub_reads
    assert_raises(ShopifyClient::Error) { CatalogSyncer.sync! }
    assert @old.reload.catalog_present
    assert_equal 'ACTIVE', @product.reload.status
    assert_empty ShopifyStockSnapshot.all
  end

  test 'malformed requested stock states roll back catalog locations levels and presence' do
    @nodes.first['status'] = 'ACTIVE'
    @stock_values.reject! { |q| q['name'] == 'on_hand' }
    stub_reads
    assert_raises(ShopifyClient::Error) { CatalogSyncer.sync! }
    assert @old.reload.catalog_present
    refute ShopifyVariant.exists?('new-variant')
    assert_equal 19, @level.reload.quantity
    assert_empty ShopifyStockSnapshot.all
  end

  test 'a complete empty catalog marks presence absent without deleting history or quantities' do
    @nodes = []
    stub_reads
    CatalogSyncer.sync!
    refute @old.reload.catalog_present
    refute @product.reload.catalog_present
    assert_equal 19, @level.reload.quantity
  end

  test 'another workspace source identity cannot be transferred by an upsert' do
    other = Tenant.create!(name: 'Other catalog', subdomain: 'other-catalog')
    ShopifyProduct.unscoped.create!(id: 'other-source-id', tenant_id: other.id, title: 'Private other product')
    @nodes.first['id'] = 'other-source-id'
    stub_reads
    assert_raises(ShopifyClient::Error) { CatalogSyncer.sync! }
    assert_equal other.id, ShopifyProduct.unscoped.find('other-source-id').tenant_id
    assert @old.reload.catalog_present
  end

  private

  def page(nodes)
    { 'nodes' => nodes, 'pageInfo' => { 'hasNextPage' => false, 'endCursor' => nil } }
  end

  def variant(id)
    { 'id' => id, 'title' => 'New pack', 'sku' => 'TEA-NEW', 'barcode' => 'fresh-barcode', 'price' => '12.00',
      'inventoryQuantity' => 3, 'inventoryItem' => { 'id' => 'source-item', 'tracked' => true } }
  end

  def stub_reads
    ShopifyClient.stubs(:graphql).with do |query, _variables|
      !query.include?('mutation')
    end.returns({})
    ShopifyClient.stubs(:graphql).with(CatalogSyncer::LOCATIONS_QUERY, { cursor: nil }).returns(
      { 'locations' => page([{ 'id' => 'source-location', 'name' => 'Online', 'isActive' => true }]) })
    ShopifyClient.stubs(:graphql).with(CatalogSyncer::PRODUCTS_QUERY, { cursor: nil }).returns({ 'products' => page(@nodes) })
    ShopifyClient.stubs(:graphql).with { |q, _| q.start_with?('query Levels') }.returns(
      { 'v0' => { 'id' => 'source-item', 'inventoryLevels' => page([{ 'location' => { 'id' => 'source-location' }, 'quantities' => @stock_values }]) } })
    ShopifyClient.stubs(:graphql).with(CatalogSyncer::ORDERS_QUERY, anything).returns({ 'orders' => page([]) })
    ShopifyClient.stubs(:graphql).with(CatalogSyncer::SHOP_QUERY, {}).returns({ 'shop' => { 'name' => 'Test' } })
  end
end
