# frozen_string_literal: true

require 'test_helper'

class NegativeInventoryTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
    @tenant = tenants(:default_tenant)
    @location = Location.create!(source: 'square', externalId: 'LOC1', name: 'Home')
    @variation = SquareVariation.create!(id: 'neg1', itemId: 'i1', sku: 'NEG1', name: 'Neg Item', tenant_id: @tenant.id)
    @level = InventoryLevel.create!(source: 'square', locationId: @location.id, squareVariationId: 'neg1',
      quantity: -5, available: -5, tenant_id: @tenant.id)
    open_push_window!('square')
  end

  teardown do
    Current.tenant = nil
  end

  test 'summary reports negative counts by source' do
    summary = NegativeInventory.summary
    assert_equal 1, summary[:total]
    assert_equal 1, summary[:square].length
    assert_equal 'NEG1', summary[:square].first.sku
    assert_equal(-5, summary[:square].first.quantity)
  end

  test 'fix! zeroes a negative Square variation, journals, and writes a physical count' do
    SquareClient.expects(:request).returns({}).at_least_once

    assert NegativeInventory.fix!(source: 'square', id: 'neg1')
    assert_equal 0, @level.reload.quantity
    movement = InventoryMovement.where(source: 'negative-fix').last
    assert_equal 'NEG1', movement.sku
    assert_equal 5, movement.delta
    assert_equal 'in', movement.direction
  end

  test 'fix! untracks a negative Shopify variant and zeroes its mirror' do
    variant = ShopifyVariant.create!(sku: 'ROUTEINS', title: 'Shipping Protection', tracked: true,
      inventoryQuantity: -4, productId: 'p1', tenant_id: @tenant.id)
    shop_location = Location.create!(source: 'shopify', externalId: 'SHOP', name: 'Shop')
    level = InventoryLevel.create!(source: 'shopify', locationId: shop_location.id, shopifyVariantId: variant.id,
      quantity: -4, available: -4, tenant_id: @tenant.id)

    assert NegativeInventory.fix!(source: 'shopify', id: variant.id)
    assert_equal 0, level.reload.quantity
    refute variant.reload.tracked
  end

  test 'fix_all! corrects every negative item' do
    SquareClient.stubs(:request).returns({})
    variant = ShopifyVariant.create!(sku: 'ROUTEINS2', title: 'Shipping', tracked: true,
      inventoryQuantity: -2, productId: 'p1', tenant_id: @tenant.id)
    shop_location = Location.create!(source: 'shopify', externalId: 'SHOP2', name: 'Shop')
    InventoryLevel.create!(source: 'shopify', locationId: shop_location.id, shopifyVariantId: variant.id,
      quantity: -2, available: -2, tenant_id: @tenant.id)

    results = NegativeInventory.fix_all!
    assert_equal 1, results[:square]
    assert_equal 1, results[:shopify]
    assert_equal 0, results[:failed]
    assert_equal 0, InventoryLevel.where(source: 'square', squareVariationId: 'neg1').first.quantity
  end

  test 'summary counts an oversold Shopify variant from its real figure, not the 0 it is stored as' do
    product = ShopifyProduct.create!(id: 'p-over', title: 'Oversold tea')
    variant = ShopifyVariant.create!(id: 'v-over', product: product, sku: 'OVER', title: 'Oversold tea 50g', tracked: true)
    shop = Location.create!(source: 'shopify', externalId: 'shop-1', name: 'Shop')
    InventoryLevel.create!(source: 'shopify', locationId: shop.externalId, shopifyVariantId: variant.id, quantity: 0, available: 0,
      sourceQuantity: -7, tenant_id: @tenant.id)
    summary = NegativeInventory.summary
    assert_equal 2, summary[:total]
    assert_equal [['OVER', -7]], summary[:shopify].map { |item| [item.sku, item.quantity] }
    assert_empty InventoryLevel.where(source: 'shopify').where('quantity < 0'), 'the fixes still select on the stored quantity'
  end
end
