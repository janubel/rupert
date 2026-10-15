# frozen_string_literal: true

require 'test_helper'

class StockReservationTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
    @actor = 'counter@example.com'
    @product = ShopifyProduct.create!(id: 'reservation-product', title: 'Reservation product')
    @variant = ShopifyVariant.create!(productId: @product.id, sku: 'RESERVE-1', title: 'Reserved widget')
    @location = Location.create!(source: 'shopify', externalId: 'reserve-location', name: 'Warehouse')
    @level = InventoryLevel.create!(source: 'shopify', locationId: @location.id,
      shopifyVariantId: @variant.id, quantity: 10, available: 8)
  end

  teardown { Current.reset }

  test 'holds reduce only local available stock and preserve mirrored quantities' do
    hold = reserve(3)
    assert hold.persisted?, hold.errors.full_messages.join(', ')
    assert_equal 5, hold.stock_reservation_pool.available_to_promise
    assert_equal 8, hold.stock_reservation_pool.mirrored_available
    assert_equal 3, hold.stock_reservation_pool.held_quantity
    assert_equal 10, @level.reload.quantity
    assert_equal 8, @level.available
    assert_equal @actor, hold.created_by
    assert hold.created_at
    assert_equal 0, InventoryMovement.count

    refused = reserve(6)
    refute refused.persisted?
    assert_match(/5 units available/, refused.errors[:quantity].join)
    assert_equal 1, StockReservation.count
  end

  test 'invalid quantities references and expiry do not allocate capacity' do
    [0, -1, '1.5', 'text', 2_147_483_648].each do |quantity|
      reservation = reserve(quantity)
      refute reservation.persisted?, "unexpected hold for #{quantity}"
      assert reservation.errors[:quantity].any?
    end
    reservation = reserve(1, reference: '')
    assert reservation.errors[:reference].any?
    reservation = reserve(1, expires_at: 1.minute.ago)
    assert reservation.errors[:expires_at].any?
    assert_equal 0, StockReservation.count
  end

  test 'release is idempotent and returns capacity with an actor and timestamp' do
    hold = reserve(8)
    StockReservationService.release(hold, actor: @actor)
    released_at = hold.released_at
    assert_equal 'released', hold.effective_status
    assert_equal 8, hold.stock_reservation_pool.available_to_promise
    StockReservationService.release(hold, actor: 'later@example.com')
    assert_equal released_at, hold.released_at
    assert_equal @actor, hold.released_by
  end

  test 'expiry stops consuming capacity without deleting the audit record' do
    hold = reserve(8, expires_at: 5.minutes.from_now)
    travel 6.minutes do
      assert_equal 'expired', hold.effective_status
      assert_equal 8, hold.stock_reservation_pool.available_to_promise
      assert_equal 'active', hold.reload.status
      assert reserve(8).persisted?
    end
    assert_equal 2, StockReservation.count
  end

  test 'same request replays without a second hold and changed payload is rejected' do
    token = SecureRandom.uuid
    hold = reserve(2, request_token: token)
    replay = reserve(2, request_token: token)
    assert_equal hold.id, replay.id
    assert_equal 1, StockReservation.count
    changed = reserve(3, request_token: token)
    refute changed.persisted?
    assert_match(/already used/, changed.errors.full_messages.join)
    StockReservationService.release(hold, actor: @actor)
    assert_equal 'released', reserve(2, request_token: token).effective_status
    assert_equal 8, hold.stock_reservation_pool.available_to_promise
  end

  test 'Shopify Square and other locations retain independent capacity even for linked SKUs' do
    hold = reserve(8)
    other_location = Location.create!(source: 'shopify', externalId: 'reserve-other', name: 'Other')
    other_level = InventoryLevel.create!(source: 'shopify', locationId: other_location.id,
      shopifyVariantId: @variant.id, quantity: 8, available: 8)
    square_item = SquareItem.create!(id: 'reservation-square-item', name: 'Square item')
    square = SquareVariation.create!(itemId: square_item.id, sku: @variant.sku, name: 'Square item')
    square_location = Location.create!(source: 'square', externalId: 'reserve-square', name: 'Shop')
    square_level = InventoryLevel.create!(source: 'square', locationId: square_location.id,
      squareVariationId: square.id, quantity: 8, available: 8)
    SkuLink.create!(sku: @variant.sku, shopifyVariantId: @variant.id, squareVariationId: square.id)
    other = reserve(8, level: other_level)
    square_hold = reserve(8, level: square_level)
    assert other.persisted?
    assert square_hold.persisted?
    assert_equal 3, StockReservationPool.count
    assert_equal 0, hold.stock_reservation_pool.available_to_promise
    assert_equal 8, square_level.reload.quantity
  end

  test 'a recreated mirror row keeps the same source-item pool and existing holds' do
    hold = reserve(6)
    @level.destroy!
    replacement = InventoryLevel.create!(source: 'shopify', locationId: @location.id,
      shopifyVariantId: @variant.id, quantity: 10, available: 8)
    refused = reserve(3, level: replacement)
    refute refused.persisted?
    assert_match(/2 units available/, refused.errors[:quantity].join)
    assert_equal hold.stock_reservation_pool_id, refused.stock_reservation_pool_id
    assert_equal 1, StockReservationPool.count
  end

  test 'a later mirror reduction clamps availability and blocks new holds' do
    hold = reserve(6)
    @level.update!(quantity: 4, available: 2)
    assert_equal 0, hold.stock_reservation_pool.available_to_promise
    refute reserve(1).persisted?
    @level.destroy!
    assert_equal 0, hold.stock_reservation_pool.available_to_promise
    assert_raises(ActiveRecord::RecordNotFound) { reserve(1) }
  end

  test 'foreign tenant inventory and inconsistent source associations cannot be reserved' do
    other = Tenant.create!(name: 'Other', subdomain: 'reservation-other')
    foreign_product = ShopifyProduct.create!(id: 'foreign-product', title: 'Secret', tenant_id: other.id)
    foreign_variant = ShopifyVariant.create!(productId: foreign_product.id, sku: 'FOREIGN', title: 'Secret', tenant_id: other.id)
    foreign_location = Location.create!(source: 'shopify', externalId: 'foreign', name: 'Secret', tenant_id: other.id)
    foreign_level = InventoryLevel.create!(source: 'shopify', locationId: foreign_location.id,
      shopifyVariantId: foreign_variant.id, quantity: 8, available: 8, tenant_id: other.id)
    assert_raises(ActiveRecord::RecordNotFound) { reserve(1, level: foreign_level) }

    @level.update!(locationId: foreign_location.id)
    assert_raises(ActiveRecord::RecordNotFound) { reserve(1) }
    @level.update!(locationId: @location.id, shopifyVariantId: foreign_variant.id)
    assert_raises(ActiveRecord::RecordNotFound) { reserve(1) }
    @level.update!(shopifyVariantId: @variant.id)
    @location.update!(source: 'square')
    assert_raises(ActiveRecord::RecordNotFound) { reserve(1) }
    assert_equal 0, StockReservation.count
  end

  test 'release cannot cross stores even with a previously loaded object' do
    hold = reserve(1)
    Current.tenant = Tenant.create!(name: 'Other release store', subdomain: 'other-release-store')
    assert_raises(ActiveRecord::RecordNotFound) { StockReservationService.release(hold, actor: @actor) }
    Current.tenant = tenants(:default_tenant)
    assert_equal 'active', hold.reload.status
  end

  test 'direct unchecked model creation and changing allocated quantity are prohibited' do
    pool = StockReservationPool.for_level!(@level)
    reservation = StockReservation.new(stock_reservation_pool: pool, quantity: 1, reference: 'direct', created_by: @actor)
    refute reservation.save
    assert_match(/reservation service/, reservation.errors.full_messages.join)
    reservation = reserve(1)
    assert_raises(ActiveRecord::ReadonlyAttributeError) { reservation.update!(quantity: 2) }
  end

  private

  def reserve(quantity, level: @level, **attributes)
    StockReservationService.reserve(inventory_level_id: level.id,
      attributes: { quantity: quantity, reference: 'Order 123' }.merge(attributes), actor: @actor)
  end
end
