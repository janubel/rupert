# frozen_string_literal: true

require 'test_helper'

class SquareClientTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
    SquareClient.stubs(:token).returns('synthetic')
  end

  teardown { Current.reset }

  test 'orders search filters and sorts on updated_at so refunds and returns re-select the order' do
    stub = stub_request(:post, 'https://connect.squareup.com/v2/orders/search')
      .with do |req|
        body = JSON.parse(req.body)
        body.dig('query', 'filter', 'date_time_filter').key?('updated_at') && body.dig('query', 'sort', 'sort_field') == 'UPDATED_AT'
      end
      .to_return(status: 200, body: { orders: [{ id: 'o1' }] }.to_json)
    assert_equal [{ 'id' => 'o1' }], SquareClient.orders(['L1'], '2026-01-01T00:00:00Z')
    assert_requested stub
  end
end
