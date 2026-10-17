# frozen_string_literal: true

require 'test_helper'

class ShopifyCountComparisonTest < ActiveSupport::TestCase
  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    EnvStore.set('SHOPIFY_SHOP_DOMAIN', 'count-test.myshopify.com')
    @at = Time.current.change(usec: 0)
    @product = ShopifyProduct.create!(id: 'native-count-product', title: 'Native count', status: 'ACTIVE',
      catalog_present: true, catalog_read_at: @at)
    @variant = ShopifyVariant.create!(id: 'native-count-variant', productId: @product.id, title: 'Native variant', sku: 'NATIVE-1',
      tracked: true, catalog_present: true, catalog_read_at: @at, inventoryItemId: 'native-count-inventory-item')
    @location = Location.create!(source: 'shopify', externalId: 'native-count-location', name: 'Native store')
    @snapshot = ShopifyStockSnapshot.create!(location: @location, shop_domain: ShopifyClient.shop_domain, captured_at: @at,
      records_json: [{ 'id' => @variant.id, 'inventory_item_id' => @variant.inventoryItemId, 'on_hand' => 15,
                       'available' => 9, 'committed' => 6 }])
    @count = InventoryCount.create!(countedAt: @at, locationId: @location.id)
    @item = @count.items.create!(sku: 'NATIVE-1', quantity: 12)
    ShopifyClient.expects(:graphql).never
  end

  teardown { Current.reset }

  test 'native on hand is independent of legacy levels and carries exact source provenance' do
    InventoryLevel.create!(source: 'shopify', locationId: @location.id, shopifyVariantId: @variant.id,
      quantity: 900, sourceQuantity: 1000)
    @count.snapshot_previous!
    assert_equal 15, @item.reload.previousQuantity
    assert_equal(-3, @item.delta)
    assert_equal @snapshot.id, @item.comparison['stock_snapshot_id']
    assert_equal @variant.id, @item.comparison['source_item_id']
    assert_equal @variant.inventoryItemId, @item.comparison['inventory_item_id']
    assert_equal @location.externalId, @item.comparison['source_location_id']
    assert_equal @snapshot.shop_domain, @item.comparison['shop_domain']
    assert_equal 'native_on_hand', @item.comparison['quantity_basis']
    assert_equal 'whole_units', @item.comparison['units']
    assert_equal @at.iso8601(6), @item.comparison['mirrored_at']
    assert_nil @item.comparison['inventory_level_id']
  end

  test 'missing duplicate fractional and out of range native stock cannot yield a delta or prepared row' do
    record = @snapshot.records.first
    [[], [record, record], [record.except('on_hand')], [record.merge('on_hand' => nil)],
      [record.merge('on_hand' => 1.5)], [record.merge('on_hand' => '15')],
      [record.merge('on_hand' => 2_147_483_648)], [record.merge('on_hand' => -2_147_483_649)]].each do |records|
      @snapshot.update!(records_json: records)
      assert_unavailable
    end
  end

  test 'zero and signed negative on hand remain distinct while physical inputs cannot be negative' do
    [0, -4, -2_147_483_648, 2_147_483_647].each do |quantity|
      @snapshot.update!(records_json: @snapshot.records.map { |record| record.merge('on_hand' => quantity) })
      @count.snapshot_previous!
      assert_equal quantity, @item.reload.previousQuantity
      assert_equal 12 - quantity, @item.delta
      assert_equal [quantity, 0].max, InventoryCountComparison.prepared_items(@count).first.quantity
    end
  end

  test 'stale future and missing snapshots stay unavailable without a legacy fallback' do
    [@at - 61.minutes, @at + 5.minutes].each do |at|
      @snapshot.update!(captured_at: at)
      assert_unavailable
    end
    @snapshot.destroy!
    assert_unavailable
  end

  test 'shop domain and selected native location must still match the counted identity' do
    @count.snapshot_previous!
    @snapshot.update!(shop_domain: 'another-shop.myshopify.com')
    assert_unavailable
    @snapshot.update!(shop_domain: ShopifyClient.shop_domain)
    @location.update!(externalId: 'changed-native-location')
    2.times { assert_unavailable(prepared: false) }
  end

  test 'archived absent untracked and different catalog epochs cannot produce physical count comparisons' do
    [{ status: 'ARCHIVED' }, { catalog_present: false }, { catalog_read_at: @at - 1.second }].each do |changes|
      @product.update!(changes)
      assert_unavailable
      @product.update!(status: 'ACTIVE', catalog_present: true, catalog_read_at: @at)
    end
    [{ tracked: false }, { catalog_present: false }, { catalog_read_at: @at - 1.second }].each do |changes|
      @variant.update!(changes)
      assert_unavailable
      @variant.update!(tracked: true, catalog_present: true, catalog_read_at: @at)
    end
  end

  test 'missing or changed inventory item identity cannot be substituted on a second check' do
    @count.snapshot_previous!
    @variant.update!(inventoryItemId: 'replaced-native-inventory-item')
    @snapshot.update!(records_json: @snapshot.records.map { |record| record.merge('inventory_item_id' => @variant.inventoryItemId) })
    2.times { assert_unavailable(prepared: false) }
    assert_equal 'native-count-inventory-item', @item.reload.comparison['inventory_item_id']
  end

  test 'inactive location and foreign workspace context have no native stock comparison' do
    @location.update!(active: false)
    assert_unavailable
    @location.update!(active: true)
    Current.tenant = Tenant.create!(name: 'Other counts', subdomain: 'other-native-counts')
    attributes = ShopifyCountComparison.new(@count).attributes_for(@item)
    assert_nil attributes[:previousQuantity]
    assert_equal 'unavailable', attributes[:comparison_snapshot]['status']
    assert_empty ShopifyCountComparison.new(@count).prepared_items
  end

  test 'missing explicit shop configuration never accepts the legacy default domain' do
    @snapshot.update!(shop_domain: 'm11u0i-sb.myshopify.com')
    EnvStore.set('SHOPIFY_SHOP_DOMAIN', nil)
    assert_unavailable
  end

  test 'malformed mixed-platform worksheet identity never yields a numerical delta' do
    square_item = SquareItem.create!(id: 'mixed-native-square', name: 'Other source')
    square_variant = SquareVariation.create!(itemId: square_item.id, name: 'Other', sku: 'NATIVE-1')
    @item.update!(squareVariationId: square_variant.id)
    @count.snapshot_previous!
    assert_nil @item.reload.previousQuantity
    assert_nil @item.delta
    assert_match(/Square variation/, @item.comparison['reason'])
  end

  test 'submitted historical comparison values are never reinterpreted as native on hand' do
    legacy = { 'status' => 'matched', 'source' => 'shopify', 'quantity_basis' => 'available_or_legacy_aggregate',
               'location_name' => 'Original location', 'source_item_id' => @variant.id }
    @item.update!(previousQuantity: 41, comparison_snapshot: legacy)
    @count.submit!
    @snapshot.update!(records_json: [])
    @count.snapshot_previous!
    assert_equal 41, @item.reload.previousQuantity
    assert_equal legacy, @item.comparison
    assert_equal(-29, @item.delta)
  end

  private

  def assert_unavailable(prepared: true)
    @count.snapshot_previous!
    assert_nil @item.reload.previousQuantity
    assert_nil @item.delta
    assert_equal 'unavailable', @item.comparison['status']
    assert @item.comparison['reason'].present?
    assert_empty InventoryCountComparison.prepared_items(@count) if prepared
  end
end
