# frozen_string_literal: true

require 'test_helper'

class HttpRetryTest < ActiveSupport::TestCase
  GRAPHQL = 'https://synthetic.myshopify.com/admin/api/2026-07/graphql.json'

  setup do
    Current.tenant = tenants(:default_tenant)
    ShopifyClient.stubs(:shop_domain).returns('synthetic.myshopify.com')
    ShopifyClient.stubs(:token).returns('synthetic-token')
    @sleeps = []
    @previous_sleeper = HttpRetry.sleeper
    HttpRetry.sleeper = ->(seconds) { @sleeps << seconds }
  end

  teardown do
    HttpRetry.sleeper = @previous_sleeper
    Current.reset
  end

  test 'Shopify HTTP 429 is retried after Retry-After and then succeeds' do
    stub_request(:post, GRAPHQL)
      .to_return(status: 429, headers: { 'Retry-After' => '2' }, body: '')
      .then.to_return(status: 200, body: { data: { shop: { name: 'ok' } } }.to_json)
    assert_equal({ 'shop' => { 'name' => 'ok' } }, ShopifyClient.graphql('query { shop { name } }'))
    assert_equal [2.0], @sleeps
  end

  test 'Shopify THROTTLED waits for the cost bucket to refill and retries' do
    throttled = { errors: [{ message: 'Throttled', extensions: { code: 'THROTTLED' } }],
                  extensions: { cost: { requestedQueryCost: 500, throttleStatus: { currentlyAvailable: 100, restoreRate: 50 } } } }
    stub_request(:post, GRAPHQL)
      .to_return(status: 200, body: throttled.to_json)
      .then.to_return(status: 200, body: { data: { ok: true } }.to_json)
    assert_equal({ 'ok' => true }, ShopifyClient.graphql('query { shop { name } }'))
    assert_equal [8.0], @sleeps, '(500 - 100) / 50 = 8 seconds'
  end

  test 'Shopify 5xx is retried with backoff and gives up with a vendor category after the last attempt' do
    stub_request(:post, GRAPHQL).to_return(status: 503, body: 'down')
    error = assert_raises(ShopifyClient::Error) { ShopifyClient.graphql('query { shop { name } }') }
    assert_equal 'vendor', SyncFailure.category(error)
    assert_equal HttpRetry::MAX_ATTEMPTS - 1, @sleeps.length
    assert @sleeps.each_cons(2).all? { |a, b| b > a * 1.5 }, "backoff should grow: #{@sleeps.inspect}"
  end

  test 'Shopify credential and permission errors are not retried' do
    stub_request(:post, GRAPHQL).to_return(status: 401, body: 'nope')
    error = assert_raises(ShopifyClient::Error) { ShopifyClient.graphql('query { shop { name } }') }
    assert_equal 'credentials', SyncFailure.category(error)
    assert_empty @sleeps
    assert_requested :post, GRAPHQL, times: 1
  end

  test 'a read timeout is retried and surfaces as a timeout when it persists' do
    stub_request(:post, GRAPHQL).to_timeout
    error = assert_raises(Net::OpenTimeout) { ShopifyClient.graphql('query { shop { name } }') }
    assert_equal 'timeout', SyncFailure.category(error)
    assert_equal HttpRetry::MAX_ATTEMPTS - 1, @sleeps.length
  end

  test 'Square 429 honours Retry-After and succeeds on the next attempt' do
    stub_request(:get, 'https://connect.squareup.com/v2/locations')
      .to_return(status: 429, headers: { 'Retry-After' => '3' }, body: { errors: [{ code: 'RATE_LIMITED' }] }.to_json)
      .then.to_return(status: 200, body: { locations: [{ id: 'L1', status: 'ACTIVE' }] }.to_json)
    assert_equal [{ 'id' => 'L1', 'status' => 'ACTIVE' }], SquareClient.locations
    assert_equal [3.0], @sleeps
  end

  test 'Square 4xx other than 429 is not retried' do
    stub_request(:get, 'https://connect.squareup.com/v2/locations').to_return(status: 403, body: { errors: [] }.to_json)
    error = assert_raises(SquareClient::Error) { SquareClient.request('/locations') }
    assert_equal 'entitlement', SyncFailure.category(error)
    assert_empty @sleeps
  end
end
