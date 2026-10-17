# frozen_string_literal: true

require 'test_helper'

class WarehouseStockHoldTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
    @actor = users(:regular_user)
    @share = WarehouseShare.create!(name: 'Held stock vendor', priceMultiplier: 1)
    product = ShopifyProduct.create!(id: 'hold-product', title: 'Held product')
    @variant = ShopifyVariant.create!(id: 'hold-variant', product: product, title: 'Held variant', price: 10)
    @level = InventoryLevel.create!(source: 'shopify', locationId: 'hold-location', shopifyVariantId: @variant.id, quantity: 5, available: 5)
    AuthorizeNetClient.stubs(:configured?).returns(true)
  end
  teardown { Current.reset }

  def cart(quantity = 3)
    record = WarehouseCart.create!(tenant_id: Current.tenant_id, share: @share, token: SecureRandom.hex(20))
    record.add_item!(@variant, quantity: quantity)
    record
  end

  def checkout(record)
    WarehouseCheckoutService.call(share: @share, cart: record, quote_token: WarehouseCheckoutQuote.issue(record), payment_nonce: SecureRandom.hex(20))
  end

  def approved
    AuthorizeNetClient::Result.new(response_code: '1', transaction_id: 'synthetic-approved-hold')
  end

  def release(order, **overrides)
    WarehouseStockRelease.call(**{ order: order, actor: @actor, fulfilled: '1', source_confirmed: '1',
      adjusted_at: 1.minute.ago.iso8601, reference: 'SYNTHETIC-STOCK-ADJUSTMENT' }.merge(overrides))
  end

  test 'different carts cannot both spend the same remaining stock' do
    first = cart
    second = cart
    AuthorizeNetClient.expects(:charge!).once.returns(approved)
    assert_predicate checkout(first), :success?
    refute_predicate checkout(second), :success?
    assert_equal 3, WarehouseStockHold.held.sum(:quantity)
    assert_equal 2, InventoryLevel.warehouse_quantities(tenant_id: Current.tenant_id, variant_ids: [@variant.id])[@variant.id]
    assert_equal 1, Core::Payment.count
  end

  test 'unknown gateway outcomes retain stock while explicit declines release it' do
    first = cart
    second = cart
    AuthorizeNetClient.expects(:charge!).once.raises(Net::ReadTimeout)
    refute_predicate checkout(first), :success?
    refute_predicate checkout(second), :success?
    assert_equal 3, WarehouseStockHold.held.sum(:quantity)
    assert_nil WarehouseStockHold.held.sole.order_id
  end

  test 'a declined payment frees its units for another cart' do
    first = cart
    second = cart
    AuthorizeNetClient.expects(:charge!).twice.returns(AuthorizeNetClient::Result.new(response_code: '2'), approved)
    refute_predicate checkout(first), :success?
    assert_equal 0, WarehouseStockHold.held.count
    assert_predicate checkout(second), :success?
    assert_equal 3, WarehouseStockHold.held.sum(:quantity)
    assert_equal 'gateway_declined', WarehouseStockHold.where(status: 'released').sole.release_reason
  end

  test 'approved local failure retains the same hold through recovery' do
    record = cart
    AuthorizeNetClient.expects(:charge!).once.returns(approved)
    Core::OrderLine.stubs(:create!).raises(ActiveRecord::RecordInvalid.new(Core::OrderLine.new))
    refute_predicate checkout(record), :success?
    assert_equal 3, WarehouseStockHold.held.sum(:quantity)
    assert_nil WarehouseStockHold.held.sole.order_id
    Core::OrderLine.unstub(:create!)
    result = WarehouseCheckoutService.call(share: @share, cart: record.reload)
    assert_predicate result, :success?
    assert_equal result.order.id, WarehouseStockHold.held.sole.order_id
    assert_equal 1, WarehouseStockHold.count
  end

  test 'stock release requires both confirmations and a newer source snapshot' do
    AuthorizeNetClient.stubs(:charge!).returns(approved)
    order = checkout(cart).order
    travel 2.minutes do
      assert_raises(WarehouseStockRelease::Error) { release(order, fulfilled: '0') }
      assert_raises(WarehouseStockRelease::Error) { release(order, source_confirmed: '0') }
      assert_raises(WarehouseStockRelease::Error) { release(order) }
      assert_equal 3, WarehouseStockHold.held.sum(:quantity)
      @level.update!(quantity: 2, available: 2, updatedAt: Time.current)
      assert_equal 1, release(order)
      hold = WarehouseStockHold.sole
      assert_equal 'released', hold.status
      assert_equal @actor.id, hold.released_by_id
      assert_operator hold.source_refreshed_at, :>=, hold.source_adjusted_at
      assert_equal 'SYNTHETIC-STOCK-ADJUSTMENT', hold.source_adjustment_reference
      refute_includes hold.source_adjustment_reference_before_type_cast, 'SYNTHETIC-STOCK-ADJUSTMENT'
      assert_equal 'completed', order.reload.fulfillment_status
      assert_equal 2, InventoryLevel.warehouse_quantities(tenant_id: Current.tenant_id, variant_ids: [@variant.id])[@variant.id]
      assert_equal 0, release(order)
      assert_equal 1, ActivityLog.where(action: 'warehouse_stock_released').count
    end
  end

  test 'another workspace or an actor without inventory permission cannot release stock' do
    AuthorizeNetClient.stubs(:charge!).returns(approved)
    order = checkout(cart).order
    reader = User.create!(tenant_id: Current.tenant_id, email: 'holds-reader@example.invalid', role: 'reader', password: 'synthetic-password')
    travel 2.minutes do
      assert_raises(WarehouseStockRelease::Error) { release(order, actor: reader) }
      other = Tenant.create!(name: 'Other hold workspace', subdomain: 'other-holds')
      Current.set(tenant: other) { assert_raises(WarehouseStockRelease::Error) { release(order) } }
    end
    assert_equal 3, WarehouseStockHold.held.sum(:quantity)
  end
end
