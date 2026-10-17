# frozen_string_literal: true

require 'test_helper'

class WarehouseCheckoutServiceTest < ActiveSupport::TestCase
  setup do
    Current.tenant = Tenant.create!(name: 'Checkout Co', subdomain: 'checkoutco')
    @share = WarehouseShare.create!(name: 'Vendor A', token: 'share-token', priceMultiplier: 0.85)
    @product = ShopifyProduct.create!(id: 'prod-checkout-1', title: 'Widgets')
    @variant = ShopifyVariant.create!(title: 'Widget', sku: 'WDG-1', price: 10.0, tracked: true, productId: @product.id)
    @cart = WarehouseCart.create!(tenant_id: Current.tenant_id, share_id: @share.id, token: 'cart-token',
      status: 'open')
    @cart.items.create!(
      tenant_id: Current.tenant_id,
      share_id: @share.id,
      variant_id: @variant.id,
      quantity: 2,
      sku: 'WDG-1',
      title: 'Widget',
      unit_cents: 850,
      line_cents: 1700
    )
    InventoryLevel.create!(source: 'shopify', locationId: 'loc-1', shopifyVariantId: @variant.id, quantity: 5,
      available: 5)
  end

  teardown do
    Current.tenant = nil
  end

  def approved_charge
    AuthorizeNetClient::Result.new(transaction_id: 'txn-1', auth_code: 'AUTH', response_code: '1', message: 'Approved')
  end

  def stub_gateway
    AuthorizeNetClient.stubs(:configured?).returns(true)
    AuthorizeNetClient.stubs(:charge!).returns(approved_charge)
  end

  test 'a second checkout attempt on the same cart is refused' do
    stub_gateway

    first = WarehouseCheckoutService.call(share: @share, cart: @cart, shipping: {}, payment_nonce: 'nonce')
    assert_predicate first, :success?
    assert_equal 1, Core::Order.count

    @cart.reload
    assert_predicate @cart, :checked_out?

    second = WarehouseCheckoutService.call(share: @share, cart: @cart, shipping: {}, payment_nonce: 'nonce')
    assert_predicate second, :success?
    assert_equal second.order.id, first.order.id
    assert_equal 1, Core::Order.count
    assert_equal 1, Core::Payment.count
  end

  test 'a retried checkout after the first response was lost reuses the same order' do
    stub_gateway

    first = WarehouseCheckoutService.call(share: @share, cart: @cart, shipping: {}, payment_nonce: 'nonce')
    assert_predicate first, :success?
    assert_equal "wh-#{@cart.id}", first.order.source_order_id

    # The cart is already checked out (the first request committed); a second
    # POST resolves to the existing order instead of charging again.
    retry_result = WarehouseCheckoutService.call(share: @share, cart: @cart, shipping: {}, payment_nonce: 'nonce')
    assert_predicate retry_result, :success?
    assert_equal first.order.id, retry_result.order.id
    assert_equal 1, Core::Payment.count
  end

  test 'a declined payment leaves the cart open and creates no order' do
    AuthorizeNetClient.stubs(:configured?).returns(true)
    AuthorizeNetClient.stubs(:charge!).returns(
      AuthorizeNetClient::Result.new(transaction_id: nil, auth_code: nil, response_code: '2', message: 'Declined')
    )

    result = WarehouseCheckoutService.call(share: @share, cart: @cart, shipping: {}, payment_nonce: 'nonce')
    refute_predicate result, :success?
    assert_match(/declined/i, result.error)
    @cart.reload
    refute_predicate @cart, :checked_out?
    assert_equal 0, Core::Order.count
  end

  test 'an unknown payment blocks new charges and cart edits' do
    AuthorizeNetClient.stubs(:configured?).returns(true)
    AuthorizeNetClient.expects(:charge!).once.raises(Net::ReadTimeout)
    first = WarehouseCheckoutService.call(share: @share, cart: @cart, payment_nonce: 'nonce-one')
    refute_predicate first, :success?
    assert_equal 'unknown', @cart.warehouse_payment_attempts.sole.status
    assert_raises(WarehouseCart::PaymentLocked) { @cart.add_item!(@variant) }
    assert_raises(WarehouseCart::PaymentLocked) { @cart.set_quantity!(@cart.items.first.id, 3) }
    assert_raises(WarehouseCart::PaymentLocked) { @cart.remove_item!(@cart.items.first.id) }
    retry_result = WarehouseCheckoutService.call(share: @share, cart: @cart.reload, payment_nonce: 'nonce-two')
    refute_predicate retry_result, :success?
    assert_equal 0, Core::Order.count
  end

  test 'only an explicit decline permits a new payment token' do
    AuthorizeNetClient.stubs(:configured?).returns(true)
    declined = AuthorizeNetClient::Result.new(response_code: '2')
    AuthorizeNetClient.expects(:charge!).twice.returns(declined, approved_charge)
    refute_predicate WarehouseCheckoutService.call(share: @share, cart: @cart, payment_nonce: 'nonce-one'), :success?
    assert_predicate WarehouseCheckoutService.call(share: @share, cart: @cart.reload, payment_nonce: 'nonce-two'), :success?
    assert_equal %w[declined paid], @cart.warehouse_payment_attempts.order(:id).pluck(:status)
  end

  test 'approval without a transaction id remains unresolved' do
    AuthorizeNetClient.stubs(:configured?).returns(true)
    AuthorizeNetClient.expects(:charge!).once.returns(AuthorizeNetClient::Result.new(response_code: '1'))
    refute_predicate WarehouseCheckoutService.call(share: @share, cart: @cart, payment_nonce: 'nonce-one'), :success?
    refute_predicate WarehouseCheckoutService.call(share: @share, cart: @cart.reload, payment_nonce: 'nonce-two'), :success?
    assert_equal 'unknown', @cart.warehouse_payment_attempts.sole.status
  end
end
