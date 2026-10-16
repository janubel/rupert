# frozen_string_literal: true

require 'test_helper'
require_relative '../support/influencer_cms_setup'

class ShopifyDiscountApiTest < ActiveSupport::TestCase
  include InfluencerCmsSetup
  setup do
    setup_influencer_cms
    EnvStore.set('SHOPIFY_SHOP_DOMAIN', 'creator-test.myshopify.com')
    EnvStore.set('SHOPIFY_CLIENT_ID', 'test-client')
    EnvStore.set('SHOPIFY_CLIENT_SECRET', 'private-test-secret')
    @endpoint = 'https://creator-test.myshopify.com/admin/api/2026-07/graphql.json'
    @token_stub = stub_request(:post, 'https://creator-test.myshopify.com/admin/oauth/access_token')
      .with(body: { client_id: 'test-client', client_secret: 'private-test-secret', grant_type: 'client_credentials' }.to_json)
      .to_return(status: 200, body: { access_token: 'private-test-token' }.to_json)
    @shop = { 'id' => 'gid://shopify/Shop/123', 'myshopifyDomain' => 'creator-test.myshopify.com', 'currencyCode' => 'USD',
              'primaryDomain' => { 'url' => @campaign.storefront_url } }
  end
  teardown { Current.reset }

  def api_response(operation, data)
    stub_request(:post, @endpoint).with do |request|
      request.headers['X-Shopify-Access-Token'] == 'private-test-token' && JSON.parse(request.body)['query'] == Marketing::ShopifyDiscountApi::QUERIES.fetch(operation)
    end.to_return(status: 200, body: { data: data }.to_json)
  end

  test 'preflight verifies exact store and real granted scopes with captured credentials' do
    api_response('shop', { shop: @shop, currentAppInstallation: { accessScopes: [{ handle: 'write_discounts' }] } })
    api = Marketing::ShopifyDiscountApi.new
    assert_equal @shop, api.shop
    assert_requested @token_stub, times: 1
    EnvStore.set('SHOPIFY_SHOP_DOMAIN', 'other-store.myshopify.com')
    # This object continues to target the store it authenticated, never a newly
    # configured host with an old token. Each workflow builds a fresh client.
    assert_equal 'creator-test.myshopify.com', api.shop_domain
    assert_equal @shop, api.shop
    assert_requested @token_stub, times: 1
  end

  test 'missing scope wrong store and missing credentials fail without creating a discount' do
    api_response('shop', { shop: @shop, currentAppInstallation: { accessScopes: [{ handle: 'read_products' }] } })
    error = assert_raises(Marketing::ShopifyDiscountApi::Error) { Marketing::ShopifyDiscountApi.new.shop }
    assert_includes error.message, 'write_discounts'
    @shop['myshopifyDomain'] = 'unrelated.myshopify.com'
    api_response('shop', { shop: @shop, currentAppInstallation: { accessScopes: [{ handle: 'write_discounts' }] } })
    assert_raises(Marketing::ShopifyDiscountApi::Error) { Marketing::ShopifyDiscountApi.new.shop }
    EnvStore.set('SHOPIFY_SHOP_DOMAIN', nil)
    assert_raises(Marketing::ShopifyDiscountApi::Error) { Marketing::ShopifyDiscountApi.new }
  end

  test 'creation requires mechanical confirmation and submits variables to the pinned API' do
    input = Marketing::ShopifyDiscountTerms.build({ code: 'CREATOR15', kind: 'percentage', value: '15', minimum_subtotal: '0', usage_limit: '25', once_per_customer: '1', starts_at: 1.hour.ago, ends_at: 1.week.from_now }, title: 'Reviewed offer')
    mutation = api_response('create', { discountCodeBasicCreate: { codeDiscountNode: { id: 'gid://shopify/DiscountCodeNode/123' }, userErrors: [] } })
    api = Marketing::ShopifyDiscountApi.new
    assert_raises(PlatformPushGuard::UnconfirmedError) { api.create(input) }
    assert_not_requested mutation
    Current.confirm_push!
    assert_equal 'gid://shopify/DiscountCodeNode/123', api.create(input)
    assert_requested(:post, @endpoint, times: 1) do |request|
      JSON.parse(request.body)['variables'] == { 'input' => input }
    end
  end

  test 'lookup distinguishes absent codes from incomplete or rejected responses' do
    api_response('lookup', { codeDiscountNodeByCode: nil })
    api = Marketing::ShopifyDiscountApi.new
    assert_nil api.lookup('MISSING15')
    api_response('lookup', {})
    assert_raises(Marketing::ShopifyDiscountApi::Error) { api.lookup('MISSING15') }
  end

  test 'mutation user errors are definitive but network and malformed results are uncertain and never retried' do
    Current.confirm_push!
    api_response('create', { discountCodeBasicCreate: { codeDiscountNode: nil, userErrors: [{ field: ['code'], message: 'Taken' }] } })
    api = Marketing::ShopifyDiscountApi.new
    assert_raises(Marketing::ShopifyDiscountApi::Rejected) { api.create({}) }
    timeout = stub_request(:post, @endpoint).to_timeout
    assert_raises(Marketing::ShopifyDiscountApi::Error) { api.create({}) }
    assert_requested timeout, times: 2 # One prior mutation and one timed-out request, no retry.
    stub_request(:post, @endpoint).to_return(status: 500, body: 'private-test-secret private-test-token')
    error = assert_raises(Marketing::ShopifyDiscountApi::Error) { api.create({}) }
    refute_includes error.message, 'private-test'
    stub_request(:post, @endpoint).to_return(status: 200, body: 'not-json')
    assert_raises(Marketing::ShopifyDiscountApi::Error) { api.create({}) }
  end
end
