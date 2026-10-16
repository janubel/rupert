# frozen_string_literal: true

require 'test_helper'

class SyncHttpDiagnosticsTest < ActiveSupport::TestCase
  setup do
    Current.user = users(:regular_user)
    ShopifyClient.stubs(:shop_domain).returns('synthetic.myshopify.com')
    ShopifyClient.stubs(:token).returns('synthetic-token')
  end
  teardown { Current.reset }

  test 'HTTP failures have safe typed categories without raw vendor payloads' do
    { 401 => 'credentials', 403 => 'entitlement', 429 => 'rate_limit', 503 => 'vendor' }.each do |status, category|
      stub_request(:post, 'https://synthetic.myshopify.com/admin/api/2026-07/graphql.json').to_return(status: status, body: 'private-vendor-payload')
      error = assert_raises(ShopifyClient::Error) { ShopifyClient.graphql('query { shop { name } }') }
      assert_equal category, SyncFailure.category(error)
      refute_includes error.message, 'private-vendor-payload'
      stub_request(:get, 'https://connect.squareup.com/v2/locations').to_return(status: status, body: { errors: [{ detail: 'private-vendor-payload' }] }.to_json)
      error = assert_raises(SquareClient::Error) { SquareClient.request('/locations') }
      assert_equal category, SyncFailure.category(error)
      refute_includes error.message, 'private-vendor-payload'
    end
  end

  test 'HTTP 200 GraphQL errors are categorized from stable codes rather than messages' do
    { 'THROTTLED' => 'rate_limit', 'ACCESS_DENIED' => 'access', 'INTERNAL_SERVER_ERROR' => 'vendor' }.each do |code, category|
      stub_request(:post, 'https://synthetic.myshopify.com/admin/api/2026-07/graphql.json').to_return(status: 200,
        body: { errors: [{ message: 'private-vendor-payload', extensions: { code: code } }] }.to_json)
      error = assert_raises(ShopifyClient::Error) { ShopifyClient.graphql('query { shop { name } }') }
      assert_equal category, SyncFailure.category(error)
      refute_includes error.message, 'private-vendor-payload'
    end
  end

  test 'invalid JSON is a failed read rather than a successful empty Square response' do
    stub_request(:get, 'https://connect.squareup.com/v2/locations').to_return(status: 200, body: 'invalid-private-body')
    error = assert_raises(SquareClient::Error) { SquareClient.request('/locations') }
    assert_equal 'data_contract', SyncFailure.category(error)
    refute_includes error.message, 'invalid-private-body'
  end
end
