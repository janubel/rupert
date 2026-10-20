# frozen_string_literal: true

require 'test_helper'

# Every Shopify webhook endpoint: HMAC must verify, the delivery is acknowledged
# fast (204) and the real work happens in a job. The three mandatory GDPR
# topics are required for app review; until 2026-10-20 two of them raised
# NameError after HMAC verification because the controllers named job classes
# that did not exist.
class ShopifyWebhooksTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  SECRET = 'test-secret-key'
  SHOP = 'testshop.myshopify.com' # matches tenants(:default_tenant)

  setup do
    @previous_secret = ShopifyApp.configuration.secret
    ShopifyApp.configuration.secret = SECRET
    @tenant = tenants(:default_tenant)
  end

  teardown do
    ShopifyApp.configuration.secret = @previous_secret
    Current.reset
  end

  test 'a delivery with a bad HMAC is rejected and nothing is enqueued' do
    assert_no_enqueued_jobs do
      deliver('/api/webhooks/customers_redact', 'customers/redact', { 'customer' => { 'id' => 1 } }, hmac: 'nope')
    end
    assert_response :unauthorized
  end

  test 'an unparseable body with a valid HMAC is a 400, not a crash' do
    # Sent as text so Rails' JSON parameter parser does not reject it first
    # (that path already answers 400 in production); this exercises the
    # controller's own parse of the raw body.
    body = '{not json'
    post '/api/webhooks/app_uninstalled', params: body, headers: headers_for('app/uninstalled', body).merge('CONTENT_TYPE' => 'text/plain')
    assert_response :bad_request
  end

  test 'customers/redact is accepted and strips personal data from the mirrored profile and orders' do
    Current.tenant = @tenant
    customer = Core::Customer.create!(source: 'shopify', external_id: 'gid://shopify/Customer/4242', email: 'Pat@Example.com',
      first_name: 'Pat', last_name: 'Lee', phone: '555-0100', notes: 'VIP', tags: 'vip')
    other = Core::Customer.create!(source: 'shopify', external_id: 'gid://shopify/Customer/9', email: 'keep@example.com', first_name: 'Keep')
    order = Core::Order.create!(source: 'shopify', source_order_id: 'gid://shopify/Order/777', order_number: '#777',
      occurred_at: Time.current, gross_cents: 1000, customer: customer, shipping_name: 'Pat Lee', shipping_address1: '1 Main St',
      shipping_city: 'Town', shipping_zip: '12345', shipping_phone: '555-0100')
    Current.reset

    payload = { 'shop_id' => 1, 'shop_domain' => SHOP, 'customer' => { 'id' => 4242, 'email' => 'pat@example.com', 'phone' => '555-0100' },
                'orders_to_redact' => [777] }
    assert_enqueued_with(job: CustomersRedactJob) do
      deliver('/api/webhooks/customers_redact', 'customers/redact', payload)
    end
    assert_response :no_content

    perform_enqueued_jobs

    Current.tenant = @tenant
    customer.reload
    assert_nil customer.email
    assert_nil customer.first_name
    assert_nil customer.phone
    assert_nil customer.notes
    assert_equal 'Keep', other.reload.first_name
    order.reload
    assert_nil order.shipping_name
    assert_nil order.shipping_address1
    assert_nil order.shipping_phone
    assert_equal 1000, order.gross_cents, 'the sale itself is retained'
    assert ActivityLog.where(action: 'gdpr_customer_redacted').exists?
  end

  test 'customers/data_request is accepted and recorded for the operator' do
    payload = { 'shop_domain' => SHOP, 'customer' => { 'id' => 4242, 'email' => 'pat@example.com' },
                'orders_requested' => [1, 2], 'data_request' => { 'id' => 99 } }
    assert_enqueued_with(job: CustomersDataRequestJob) do
      deliver('/api/webhooks/customers_data_request', 'customers/data_request', payload)
    end
    assert_response :no_content
    perform_enqueued_jobs
    Current.tenant = @tenant
    log = ActivityLog.find_by(action: 'gdpr_data_request')
    assert log, 'operator receives an audit-trail entry to fulfil'
    assert_includes log.details, '2 order(s)'
    refute_includes log.details, 'pat@example.com', 'the request record must not copy the customer email'
  end

  test 'shop/redact removes the Shopify session and keeps business data' do
    Shop.create!(shopify_domain: SHOP, shopify_token: 'tok')
    Current.tenant = @tenant
    Core::Customer.create!(source: 'shopify', external_id: 'gid://shopify/Customer/1', email: 'a@example.com')
    Current.reset

    deliver('/api/webhooks/shop_redact', 'shop/redact', { 'shop_id' => 1, 'shop_domain' => SHOP })
    assert_response :no_content
    perform_enqueued_jobs

    assert_not Shop.exists?(shopify_domain: SHOP)
    Current.tenant = @tenant
    assert Core::Customer.exists?(external_id: 'gid://shopify/Customer/1')
    assert ActivityLog.where(action: 'gdpr_shop_redacted').exists?
  end

  test 'app/uninstalled drops the session' do
    Shop.create!(shopify_domain: SHOP, shopify_token: 'tok')
    assert_enqueued_with(job: AppUninstalledJob) do
      deliver('/api/webhooks/app_uninstalled', 'app/uninstalled', { 'id' => 1, 'domain' => SHOP })
    end
    assert_response :no_content
    perform_enqueued_jobs
    assert_not Shop.exists?(shopify_domain: SHOP)
  end

  test 'a replayed delivery id is acknowledged once and processed once' do
    payload = { 'id' => 1, 'domain' => SHOP }
    body = payload.to_json
    headers = headers_for('app/uninstalled', body)
    assert_enqueued_jobs(1, only: AppUninstalledJob) do
      post '/api/webhooks/app_uninstalled', params: body, headers: headers
      assert_response :no_content
      post '/api/webhooks/app_uninstalled', params: body, headers: headers
      assert_response :no_content
    end
    assert_equal 1, WebhookDelivery.where(provider: 'shopify', topic: 'app/uninstalled').count
  end

  test 'a delivery for an unknown shop is acknowledged and the job does nothing' do
    deliver('/api/webhooks/customers_redact', 'customers/redact', { 'customer' => { 'id' => 1 } }, shop: 'unknown.myshopify.com')
    assert_response :no_content
    assert_nothing_raised { perform_enqueued_jobs }
  end

  private

  def deliver(path, topic, payload, hmac: nil, shop: SHOP)
    body = payload.to_json
    post path, params: body, headers: headers_for(topic, body, hmac: hmac, shop: shop)
  end

  def headers_for(topic, body, hmac: nil, shop: SHOP)
    hmac ||= Base64.strict_encode64(OpenSSL::HMAC.digest('sha256', SECRET, body))
    {
      'CONTENT_TYPE' => 'application/json',
      'X-Shopify-Topic' => topic,
      'X-Shopify-Hmac-Sha256' => hmac,
      'X-Shopify-Shop-Domain' => shop,
      'X-Shopify-Webhook-Id' => SecureRandom.uuid,
      'X-Shopify-API-Version' => ShopifyClient::API_VERSION
    }
  end
end
