# frozen_string_literal: true

require 'test_helper'

class WarehouseStockReleaseTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    share = WarehouseShare.create!(name: 'Staff fulfillment vendor', priceMultiplier: 1)
    product = ShopifyProduct.create!(id: 'release-product', title: 'Release product')
    variant = ShopifyVariant.create!(id: 'release-variant', product: product, title: 'Release variant', price: 10)
    @level = InventoryLevel.create!(source: 'shopify', locationId: 'release-location', shopifyVariantId: variant.id, quantity: 5, available: 5)
    cart = WarehouseCart.create!(tenant_id: @tenant.id, share: share, token: SecureRandom.hex(20))
    cart.add_item!(variant, quantity: 3)
    AuthorizeNetClient.stubs(:configured?).returns(true)
    AuthorizeNetClient.stubs(:charge!).returns(AuthorizeNetClient::Result.new(response_code: '1', transaction_id: 'synthetic-release-transaction'))
    @order = WarehouseCheckoutService.call(share: share, cart: cart, quote_token: WarehouseCheckoutQuote.issue(cart), payment_nonce: 'synthetic-release-nonce').order
    post login_path, params: { email: 'admin@example.com', password: 'password' }
    assert_response :redirect
  end
  teardown { Current.reset }

  test 'staff can review holds and confirm fulfilled adjusted stock without any provider write' do
    get warehouse_path
    assert_response :success
    assert_select "a[href='#{order_path(@order)}']", count: 1
    get order_path(@order)
    assert_response :success
    assert_select "form[action='#{release_warehouse_stock_order_path(@order)}']", count: 1
    assert_select "input[name='fulfillment_confirmed'][required]"
    assert_select "input[name='source_stock_confirmed'][required]"
    travel 2.minutes do
      @level.update!(quantity: 2, available: 2, updatedAt: Time.current)
      post release_warehouse_stock_order_path(@order), params: { fulfillment_confirmed: '1', source_stock_confirmed: '1',
        source_adjusted_at: 1.minute.ago.iso8601, source_adjustment_reference: 'SYNTHETIC-ADJUSTMENT' }
      assert_redirected_to order_path(@order)
      assert_equal 'released', WarehouseStockHold.unscoped.sole.status
      follow_redirect!
      assert_select "form[action='#{release_warehouse_stock_order_path(@order)}']", count: 0
    end
  end

  test 'a direct release cannot omit the staff confirmations' do
    post release_warehouse_stock_order_path(@order), params: { source_adjustment_reference: 'NOT-ENOUGH' }
    assert_redirected_to order_path(@order)
    assert_equal 'held', WarehouseStockHold.unscoped.sole.status
  end
end
