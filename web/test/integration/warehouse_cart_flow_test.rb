# frozen_string_literal: true

require 'test_helper'

class WarehouseCartFlowTest < ActionDispatch::IntegrationTest
  module TestShopifySession
    def current_shopify_session
      @test_session ||= ShopifyAPI::Auth::Session.new(
        shop: 'm11u0i-sb.myshopify.com',
        access_token: 'test-token',
        is_online: false,
        expires: Time.now + 3600
      )
    end
  end

  ShopifyApp::TokenExchange.prepend(TestShopifySession)

  setup do
    ShopifyAPI::Context.setup(
      api_key: 'test-key',
      api_secret_key: 'test-secret',
      api_version: ShopifyAPI::AdminVersions::SUPPORTED_ADMIN_VERSIONS.first,
      host_name: 'localhost',
      scope: 'read_products',
      is_private: false,
      is_embedded: false
    )
    Shop.create!(shopify_domain: 'm11u0i-sb.myshopify.com', shopify_token: 'test-token')

    @tenant = Tenant.create!(name: 'Ware Co', subdomain: 'wareco')
    Current.tenant = @tenant

    EnvStore.set('AUTHORIZE_NET_LOGIN_ID', 'testlogin')
    EnvStore.set('AUTHORIZE_NET_TRANSACTION_KEY', 'testtxnkey')
    EnvStore.set('AUTHORIZE_NET_SANDBOX', '1')

    @share = WarehouseShare.create!(name: 'Sage Supply', priceMultiplier: 0.8, tenant: @tenant)
    @location = Location.create!(source: 'shopify', externalId: 'loc-1', name: 'Main Shop', tenant_id: @tenant.id)
    @product = ShopifyProduct.create!(id: 'prod-cart', title: 'Tea', status: 'ACTIVE', tenant_id: @tenant.id)
    @variant = ShopifyVariant.create!(
      id: 'var-cart',
      productId: @product.id,
      title: '100g',
      price: 20.0,
      sku: 'TEA-100',
      tracked: true,
      tenant_id: @tenant.id
    )
    InventoryLevel.create!(
      source: 'shopify',
      locationId: @location.id,
      shopifyVariantId: @variant.id,
      quantity: 50,
      available: 50,
      tenant_id: @tenant.id
    )

    stub_request(:post, 'https://apitest.authorize.net/xml/v1/request.api')
      .to_return(status: 200, body: approved_gateway_body, headers: { 'Content-Type' => 'application/json' })
  end

  teardown do
    EnvStore.set('AUTHORIZE_NET_LOGIN_ID', nil)
    EnvStore.set('AUTHORIZE_NET_TRANSACTION_KEY', nil)
    EnvStore.set('AUTHORIZE_NET_SANDBOX', nil)
    %w[APPLE_PAY_MERCHANT_ID APPLE_PAY_IDENTITY_CERT APPLE_PAY_IDENTITY_KEY].each { |k| EnvStore.set(k, nil) }
    Current.tenant = nil
  end

  def approved_gateway_body
    {
      transactionResponse: {
        responseCode: '1',
        transId: '40001234',
        authCode: 'OK',
        messages: { code: '1', description: 'This transaction has been approved.' }
      }
    }.to_json
  end

  test 'add to cart, update quantities, and see server-priced totals' do
    get warehouse_sale_path(@share.token)
    assert_response :success
    assert_select 'a.btn-primary', /View cart/

    post warehouse_cart_add_item_path(@share.token), params: { variant_id: @variant.id, quantity: '5' }
    assert_redirected_to warehouse_cart_path(@share.token)
    follow_redirect!
    assert_response :success
    assert_select 'p', /Tea · 100g/
    assert_select 'p', /Total \$80\.00/

    cart = WarehouseCart.last
    assert_equal 5, cart.items.sum(:quantity)
    # 20.00 list × 0.8 multiplier = 16.00/unit; no tiers → 80.00.
    assert_equal 16_00, cart.items.first.unit_cents
    assert_equal 80_00, cart.items.first.line_cents

    patch warehouse_cart_item_path(@share.token, cart.items.first.id), params: { quantity: '10' }
    follow_redirect!
    cart.items.first.reload
    assert_equal 10, cart.items.first.quantity
    assert_equal 160_00, cart.items.first.line_cents
  end

  test 'checkout creates a paid canonical order and checks out the cart' do
    post warehouse_cart_add_item_path(@share.token), params: { variant_id: @variant.id, quantity: '5' }
    cart = WarehouseCart.last

    get warehouse_checkout_path(@share.token)
    assert_response :success
    assert_select 'h1', /Checkout/
    assert_select '#accept-card-number'

    orders_before = Core::Order.unscoped.count
    assert_difference 'Core::Payment.unscoped.count' do
      post warehouse_checkout_submit_path(@share.token), params: {
        shipping_name: 'Ada Vendor',
        shipping_address1: '1 Main St',
        shipping_city: 'Springfield',
        shipping_zip: '12345',
        shipping_country: 'US',
        payment_nonce: 'payment-nonce-1',
        data_descriptor: 'COMMON.ACCEPT.INAPP.PAYMENT'
      }
    end

    assert_redirected_to(%r{/w/#{@share.token}/orders/})
    assert_equal orders_before + 1, Core::Order.unscoped.count
    follow_redirect!
    assert_response :success
    assert_select 'h1', /Order confirmed/

    order = Core::Order.unscoped.last
    assert_equal 'warehouse', order.channel
    assert_equal 80_00, order.gross_cents
    assert order.paid?
    assert_equal 1, order.order_lines.count
    assert_equal 16_00, order.order_lines.first.unit_cents
    assert_equal '40001234', order.payments.first.reference
    assert_equal 'Ada Vendor', order.shipping_name
    assert_equal 5, order.line_items

    assert cart.reload.checked_out?
    other_browser = open_session
    other_browser.get warehouse_order_path(@share.token, order.order_number)
    assert_equal 404, other_browser.response.status
    other_share = WarehouseShare.create!(name: 'Another vendor', tenant: @tenant)
    get warehouse_order_path(other_share.token, order.order_number)
    assert_response :not_found
  end

  %i[get post].each do |request_method|
    test "#{request_method} after a lost successful response recovers confirmation through the browser cart" do
      post warehouse_cart_add_item_path(@share.token), params: { variant_id: @variant.id, quantity: '2' }
      cart = WarehouseCart.last
      Current.tenant = @tenant
      # The first request committed, but none of its Set-Cookie headers or redirect
      # reached the browser. It still holds the original signed cart cookie.
      result = WarehouseCheckoutService.call(share: @share, cart: cart, payment_nonce: 'lost-response-nonce',
        shipping: { shipping_name: 'Recovery customer' })
      assert_predicate result, :success?
      Current.reset

      assert_no_difference ['Core::Payment.unscoped.count', 'WarehouseCart.count'] do
        public_send(request_method, warehouse_checkout_submit_path(@share.token), params: { payment_nonce: 'retry-nonce' })
      end
      assert_redirected_to warehouse_order_path(@share.token, result.order.order_number)
      follow_redirect!
      assert_response :success
      assert_select 'h1', /Order confirmed/
      assert_requested :post, 'https://apitest.authorize.net/xml/v1/request.api', times: 1
    end
  end

  test 'declined payment leaves no paid order' do
    stub_request(:post, 'https://apitest.authorize.net/xml/v1/request.api')
      .to_return(status: 200,
        body: {
          transactionResponse: {
            responseCode: '2',
            messages: { code: '2', description: 'This transaction has been declined.' }
          }
        }.to_json,
        headers: { 'Content-Type' => 'application/json' })

    post warehouse_cart_add_item_path(@share.token), params: { variant_id: @variant.id, quantity: '2' }
    cart = WarehouseCart.last
    paid_before = Core::Order.unscoped.where(status: 'paid').count

    assert_no_difference 'Core::OrderLine.unscoped.count' do
      post warehouse_checkout_submit_path(@share.token), params: {
        shipping_name: 'Ada',
        shipping_address1: '1 Main',
        shipping_city: 'Springfield',
        shipping_zip: '12345',
        shipping_country: 'US',
        payment_nonce: 'bad-nonce'
      }
    end

    assert_response :unprocessable_entity
    assert_select "div[role='alert']", /declined/

    assert_equal paid_before, Core::Order.unscoped.where(status: 'paid').count
    refute cart.reload.checked_out?
  end

  test 'empty cart cannot reach checkout' do
    get warehouse_checkout_path(@share.token)
    assert_response :not_found
  end

  def configure_apple_pay
    key = OpenSSL::PKey::RSA.new(2048)
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = 1
    cert.subject = cert.issuer = OpenSSL::X509::Name.parse('/CN=merchant.test')
    cert.public_key = key.public_key
    cert.not_before = Time.now - 60
    cert.not_after = Time.now + 3600
    cert.sign(key, OpenSSL::Digest.new('SHA256'))
    EnvStore.set('APPLE_PAY_MERCHANT_ID', 'merchant.test.rupert')
    EnvStore.set('APPLE_PAY_IDENTITY_CERT', cert.to_pem)
    EnvStore.set('APPLE_PAY_IDENTITY_KEY', key.to_pem)
  end

  test 'apple pay button is hidden until Apple Pay is configured, then shown with the cart total' do
    post warehouse_cart_add_item_path(@share.token), params: { variant_id: @variant.id, quantity: '5' }
    get warehouse_checkout_path(@share.token)
    assert_select '[data-apple-pay-target="button"]', count: 0

    configure_apple_pay
    get warehouse_checkout_path(@share.token)
    assert_select '[data-apple-pay-target="button"]', count: 1
    assert_select 'form[data-apple-pay-total-value="80.00"]'
  end

  test 'apple pay session is 404 when not configured and refuses non-Apple validation URLs' do
    post warehouse_cart_add_item_path(@share.token), params: { variant_id: @variant.id, quantity: '1' }
    post warehouse_apple_pay_session_path(@share.token), params: { validation_url: 'https://apple-pay-gateway.apple.com/x' }
    assert_response :not_found

    configure_apple_pay
    post warehouse_apple_pay_session_path(@share.token), params: { validation_url: 'https://evil.example.com/paymentservices/startSession' }
    assert_response :unprocessable_entity
    assert_not_requested :post, 'https://evil.example.com/paymentservices/startSession'
  end

  test 'apple pay session relays Apple response using merchant id and request domain' do
    configure_apple_pay
    post warehouse_cart_add_item_path(@share.token), params: { variant_id: @variant.id, quantity: '1' }
    apple = stub_request(:post, 'https://apple-pay-gateway.apple.com/paymentservices/startSession').with { |req|
      body = JSON.parse(req.body)
      body['merchantIdentifier'] == 'merchant.test.rupert' && body['initiative'] == 'web' &&
        body['displayName'] == 'Sage Supply' && body['initiativeContext'].present?
    }.to_return(status: 200, body: { merchantSessionIdentifier: 'abc' }.to_json)

    post warehouse_apple_pay_session_path(@share.token),
      params: { validation_url: 'https://apple-pay-gateway.apple.com/paymentservices/startSession' }

    assert_requested apple
    assert_response :success
    assert_equal 'abc', response.parsed_body['merchantSessionIdentifier']
  end

  test 'apple pay token is charged through Authorize.net with the apple descriptor' do
    post warehouse_cart_add_item_path(@share.token), params: { variant_id: @variant.id, quantity: '5' }
    charge = stub_request(:post, 'https://apitest.authorize.net/xml/v1/request.api').with { |req|
      payment = JSON.parse(req.body).dig('createTransactionRequest', 'transactionRequest', 'payment', 'opaqueData')
      payment == { 'dataDescriptor' => 'COMMON.APPLE.INAPP.PAYMENT', 'dataValue' => 'YXBwbGUtdG9rZW4=' }
    }.to_return(status: 200, body: approved_gateway_body)

    post warehouse_checkout_submit_path(@share.token), params: {
      shipping_name: 'Ada Vendor', shipping_address1: '1 Main St', shipping_city: 'Springfield',
      shipping_zip: '12345', shipping_country: 'US',
      payment_nonce: 'YXBwbGUtdG9rZW4=', data_descriptor: 'COMMON.APPLE.INAPP.PAYMENT'
    }

    assert_requested charge
    assert_redirected_to(%r{/w/#{@share.token}/orders/})
  end

  test 'unknown payment descriptors fall back to the card descriptor' do
    stub = stub_request(:post, 'https://apitest.authorize.net/xml/v1/request.api').with { |req|
      JSON.parse(req.body).dig('createTransactionRequest', 'transactionRequest', 'payment', 'opaqueData', 'dataDescriptor') ==
        'COMMON.ACCEPT.INAPP.PAYMENT'
    }.to_return(status: 200, body: approved_gateway_body)

    AuthorizeNetClient.charge!(amount_cents: 100, payment_nonce: 'n', data_descriptor: 'SOMETHING.ELSE')

    assert_requested stub
  end

  test 'google pay button shows in sandbox and its token is charged with the google descriptor' do
    post warehouse_cart_add_item_path(@share.token), params: { variant_id: @variant.id, quantity: '5' }
    get warehouse_checkout_path(@share.token)
    assert_select '[data-google-pay-target="button"]', count: 1
    assert_select 'form[data-google-pay-environment-value="TEST"][data-google-pay-login-id-value="testlogin"]'
    assert_select 'form[data-google-pay-total-value="80.00"]'

    charge = stub_request(:post, 'https://apitest.authorize.net/xml/v1/request.api').with { |req|
      JSON.parse(req.body).dig('createTransactionRequest', 'transactionRequest', 'payment', 'opaqueData') ==
        { 'dataDescriptor' => 'COMMON.GOOGLE.INAPP.PAYMENT', 'dataValue' => 'Z29vZ2xlLXRva2Vu' }
    }.to_return(status: 200, body: approved_gateway_body)
    post warehouse_checkout_submit_path(@share.token), params: {
      shipping_name: 'Ada Vendor', shipping_address1: '1 Main St', shipping_city: 'Springfield',
      shipping_zip: '12345', shipping_country: 'US',
      payment_nonce: 'Z29vZ2xlLXRva2Vu', data_descriptor: 'COMMON.GOOGLE.INAPP.PAYMENT'
    }
    assert_requested charge
  end

  test 'google pay is hidden in production until a merchant id is saved' do
    EnvStore.set('AUTHORIZE_NET_SANDBOX', '0')
    stub_request(:post, 'https://api.authorize.net/xml/v1/request.api')
    post warehouse_cart_add_item_path(@share.token), params: { variant_id: @variant.id, quantity: '1' }
    get warehouse_checkout_path(@share.token)
    assert_select '[data-google-pay-target="button"]', count: 0

    EnvStore.set('GOOGLE_PAY_MERCHANT_ID', 'BCR2DN4TEST')
    get warehouse_checkout_path(@share.token)
    assert_select '[data-google-pay-target="button"]', count: 1
    assert_select 'form[data-google-pay-environment-value="PRODUCTION"]'
  ensure
    EnvStore.set('GOOGLE_PAY_MERCHANT_ID', nil)
  end

  test 'checkout page has no raw card inputs, only hosted fields and wallet tokens' do
    post warehouse_cart_add_item_path(@share.token), params: { variant_id: @variant.id, quantity: '1' }
    get warehouse_checkout_path(@share.token)
    assert_select 'input[name*="card"], input[autocomplete^="cc-"]', count: 0
  end
end
