# frozen_string_literal: true

require 'test_helper'

class InventoryCountComparisonTest < ActiveSupport::TestCase
  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    @product = ShopifyProduct.create!(id: 'count-comparison-product', title: 'Count product')
    @variant = ShopifyVariant.create!(productId: @product.id, sku: 'EXACT-1', title: 'First')
    @location = Location.create!(source: 'shopify', externalId: 'exact-location', name: 'Chosen')
    @other_location = Location.create!(source: 'shopify', externalId: 'other-location', name: 'Other')
    @level = InventoryLevel.create!(source: 'shopify', locationId: @location.id, shopifyVariantId: @variant.id, quantity: 10, sourceQuantity: 10)
    InventoryLevel.create!(source: 'shopify', locationId: @other_location.id, shopifyVariantId: @variant.id, quantity: 90, sourceQuantity: 90)
    @count = InventoryCount.create!(countedAt: Time.current, locationId: @location.id)
    @row = @count.items.create!(sku: 'EXACT-1', quantity: 7)
  end

  teardown { Current.reset }

  test 'snapshot uses one location and freezes identity labels and quantity' do
    @count.snapshot_previous!
    assert_equal 10, @row.reload.previousQuantity
    assert_equal(-3, @row.delta)
    assert_equal @variant.id, @row.comparison['source_item_id']
    assert_equal @level.id, @row.comparison['inventory_level_id']
    assert_equal 'available_or_legacy_aggregate', @row.comparison['quantity_basis']
    @location.update!(name: 'Renamed')
    @level.update!(quantity: 200, sourceQuantity: 200)
    SkuLink.create!(sku: 'EXACT-1', shopifyVariantId: nil)
    assert_equal 'Chosen', @row.reload.comparison['location_name']
    assert_equal 10, @row.previousQuantity
  end

  test 'missing location or stock row stays unknown instead of aggregating or inventing zero' do
    @count.update!(locationId: nil)
    @count.snapshot_previous!
    assert_nil @row.reload.previousQuantity
    assert_nil @row.delta
    @count.update!(locationId: @location.id)
    @level.destroy!
    @count.snapshot_previous!
    assert_nil @row.reload.previousQuantity
    assert_match(/No unambiguous stored stock row/, @row.comparison_label)
  end

  test 'real zero and oversold available quantities remain distinct from missing stock' do
    @level.update!(quantity: 0, sourceQuantity: 0)
    @count.snapshot_previous!
    assert_equal 0, @row.reload.previousQuantity
    assert_equal 7, @row.delta
    @level.update!(sourceQuantity: -4)
    @count.snapshot_previous!
    assert_equal(-4, @row.reload.previousQuantity)
    assert_equal 11, @row.delta
    assert_equal 0, InventoryCountComparison.prepared_items(@count).first.quantity
  end

  test 'square source uses its own location and variation without adding shopify stock' do
    item = SquareItem.create!(id: 'count-comparison-square', name: 'Square product')
    variation = SquareVariation.create!(itemId: item.id, name: 'First', sku: 'EXACT-1')
    location = Location.create!(source: 'square', externalId: 'square-exact', name: 'Register')
    InventoryLevel.create!(source: 'square', locationId: location.id, squareVariationId: variation.id, quantity: 6)
    @count.update!(locationId: location.id)
    @count.snapshot_previous!
    assert_equal 6, @row.reload.previousQuantity
    assert_equal 1, @row.delta
    assert_equal variation.id, @row.squareVariationId
    assert_equal 'in_stock', @row.comparison['quantity_basis']
    prepared = InventoryCountComparison.prepared_items(@count)
    assert_equal ['EXACT-1'], prepared.map(&:sku)
    assert_equal 6, prepared.first.quantity
  end

  test 'duplicate source sku or worksheet rows never produce an arbitrary comparison' do
    duplicate = ShopifyVariant.create!(productId: @product.id, sku: 'EXACT-1', title: 'Duplicate')
    @count.snapshot_previous!
    assert_nil @row.reload.delta
    assert_match(/does not identify one item/, @row.comparison_label)
    assert_empty InventoryCountComparison.prepared_items(@count)
    duplicate.destroy!
    @count.items.create!(sku: 'EXACT-1', quantity: 1)
    @count.snapshot_previous!
    assert_nil @row.reload.delta
    assert_match(/Duplicate SKU rows/, @row.comparison_label)
  end

  test 'scanned identity cannot silently switch to a different mapped variant' do
    @row.update!(shopifyVariantId: @variant.id)
    @variant.update!(sku: 'OLD-1')
    replacement = ShopifyVariant.create!(productId: @product.id, sku: 'EXACT-1', title: 'Replacement')
    InventoryLevel.create!(source: 'shopify', locationId: @location.id, shopifyVariantId: replacement.id, quantity: 50)
    @count.snapshot_previous!
    assert_nil @row.reload.previousQuantity
    assert_equal @variant.id, @row.shopifyVariantId
    assert_match(/identity changed/, @row.comparison_label)
  end

  test 'malformed mixed-platform stock rows cannot be accepted' do
    item = SquareItem.create!(id: 'count-comparison-square', name: 'Square product')
    variation = SquareVariation.create!(itemId: item.id, name: 'First', sku: 'EXACT-1')
    @level.update!(squareVariationId: variation.id)
    @count.snapshot_previous!
    assert_nil @row.reload.previousQuantity
    assert_nil @row.delta
  end

  test 'a link into another tenant cannot provide an item or a comparison' do
    other = Tenant.create!(name: 'Other', subdomain: "count-other-#{SecureRandom.hex(3)}")
    Current.tenant = other
    product = ShopifyProduct.create!(id: 'count-comparison-other', title: 'Other product')
    variant = ShopifyVariant.create!(productId: product.id, title: 'Other variant', sku: 'OTHER-1')
    Current.tenant = @tenant
    @row.update!(sku: 'OTHER-1')
    SkuLink.create!(sku: 'OTHER-1', shopifyVariantId: variant.id)
    @count.snapshot_previous!
    assert_nil @row.reload.previousQuantity
    assert_nil @row.delta
    assert_match(/no longer in this workspace/, @row.comparison_label)
  end

  test 'different worksheet skus sharing one source item do not double compare its pool' do
    SkuLink.create!(sku: 'ALIAS-1', shopifyVariantId: @variant.id)
    alias_row = @count.items.create!(sku: 'ALIAS-1', quantity: 2)
    @count.snapshot_previous!
    [@row, alias_row].each do |row|
      assert_nil row.reload.previousQuantity
      assert_nil row.delta
      assert_match(/same platform stock pool/, row.comparison_label)
    end
  end

  test 'historical totals without pool provenance are retained but have no trusted delta' do
    @row.update!(previousQuantity: 100, comparison_snapshot: nil)
    assert_equal 100, @row.previousQuantity
    assert_nil @row.delta
    assert_match(/Legacy total/, @row.comparison_label)
  end
end
