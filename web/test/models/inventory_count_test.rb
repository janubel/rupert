# frozen_string_literal: true

require 'test_helper'

class InventoryCountTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
    @tenant = tenants(:default_tenant)
    @product = ShopifyProduct.create!(id: 'prod-1', title: 'Widget', tenant_id: @tenant.id)
    @shopify_variant = ShopifyVariant.create!(title: 'Widget - Small', sku: 'WIDGET-S',
      productId: @product.id, tenant_id: @tenant.id)
    @square_item = SquareItem.create!(id: 'sqitem-1', name: 'Widget', tenant_id: @tenant.id)
    @square_variation = SquareVariation.create!(name: 'Small', sku: 'WIDGET-S',
      itemId: @square_item.id, tenant_id: @tenant.id)
    SkuLink.create!(sku: 'WIDGET-S', shopifyVariantId: @shopify_variant.id,
      squareVariationId: @square_variation.id, tenant_id: @tenant.id)
    @location = Location.create!(source: 'shopify', externalId: 'loc-1', name: 'Main',
      tenant_id: @tenant.id)
    InventoryLevel.create!(source: 'shopify', locationId: @location.id,
      shopifyVariantId: @shopify_variant.id, quantity: 10, tenant_id: @tenant.id)

    @count = InventoryCount.create!(countedAt: Time.current, createdBy: 'tester',
      tenant_id: @tenant.id)
    @item = @count.items.create!(sku: 'WIDGET-S', quantity: 7, tenant_id: @tenant.id)
  end

  teardown { Current.tenant = nil }

  test 'draft submits to pending and rejects back to draft' do
    assert @count.draft?
    @count.snapshot_previous!
    @count.submit!
    assert @count.pending?

    @count.reject!
    assert @count.rejected?
    @count.reopen!
    assert @count.draft?
  end

  test 'snapshot freezes the system total and linked variant ids' do
    @count.snapshot_previous!
    @item.reload
    assert_equal 10, @item.previousQuantity
    assert_equal @shopify_variant.id, @item.shopifyVariantId
    assert_equal @square_variation.id, @item.squareVariationId
  end

  test 'approving a count is record-only: no override, no movements' do
    @count.snapshot_previous!
    @count.submit!
    @count.approve!
    @count.apply_override!(actor: 'approver')
    assert @count.approved?
    assert @count.appliedAt.present?

    level = InventoryLevel.find_by(source: 'shopify', shopifyVariantId: @shopify_variant.id)
    assert_equal 10, level.quantity
    assert_equal 10, InventoryLevel.total_for_variant(@shopify_variant.id)
    refute InventoryMovement.exists?(sku: 'WIDGET-S')
    refute @item.reload.applied?
  end

  test 'approving never creates square levels or manual override locations' do
    @count.snapshot_previous!
    @count.submit!
    @count.approve!
    @count.apply_override!(actor: 'approver')

    refute InventoryLevel.exists?(source: 'square', squareVariationId: @square_variation.id)
    refute Location.exists?(name: 'Manual override')
  end

  test 'unlinked skus are snapshotted but not applied' do
    item = @count.items.create!(sku: 'UNLINKED', quantity: 3, tenant_id: @tenant.id)
    @count.snapshot_previous!
    assert_equal 0, item.reload.previousQuantity
    assert_nil item.shopifyVariantId

    @count.submit!
    @count.approve!
    @count.apply_override!
    refute item.reload.applied?
  end

  test 'apply_override! does nothing unless approved' do
    refute @count.apply_override!
    assert_nil @count.appliedAt
  end

  test 'resolves product title and thumbnail for the count sheet' do
    @product.update!(featuredImageUrl: 'https://cdn.shopify.com/s/files/1/x/widget.jpg')
    @count.snapshot_previous!
    @item.reload
    assert_equal 'Widget - Small', @item.inventory_title
    assert_includes @item.inventory_thumbnail, 'https://cdn.shopify.com/s/files/1/x/widget.jpg'
  end

  test 'count quantities validate raw whole numbers and the shared database integer limit' do
    [nil, '', 'not a number', '1.5', '-1', '2147483648', '999999999999999999999999999999999999'].each do |quantity|
      @item.quantity = quantity
      refute @item.valid?, "expected #{quantity.inspect} to be rejected"
      assert @item.errors.added?(:quantity, :not_a_number) || @item.errors[:quantity].any?
    end
    [0, 2_147_483_647].each do |quantity|
      @item.quantity = quantity
      assert @item.valid?, @item.errors.full_messages.to_sentence
    end
  end
end
