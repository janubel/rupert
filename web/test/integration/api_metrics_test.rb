# frozen_string_literal: true

require 'test_helper'

class ApiMetricsTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = tenants(:default_tenant)
    @owner = users(:regular_user)
    Current.tenant = @tenant
    order = Core::Order.create!(source: 'shopify', source_order_id: 'api-m1', occurred_at: 1.day.ago.change(hour: 12), gross_cents: 21_483, tax_cents: 0, currency: 'USD')
    order.mark_paid!
  end

  teardown { Current.reset }

  def bearer(scopes)
    _, secret = ApiAccessToken.issue(attributes: { name: 'Metrics', scopes: scopes }, user: @owner.reload, tenant: @tenant)
    { 'Authorization' => "Bearer #{secret}" }
  end

  test 'the catalog and one metric, behind reports:read' do
    headers = bearer(['reports:read'])
    get api_v1_metrics_path, headers: headers
    assert_response :success
    assert_includes response.parsed_body['data'].pluck('name'), 'gross_sales'

    get api_v1_metric_path('gross_sales'), params: { period: 'yesterday' }, headers: headers
    assert_response :success
    data = response.parsed_body['data']
    assert_equal ['$214.83', 'gross_sales'], [data['values'].first['formatted'], data['metric']]
    assert_equal 'previous', data['compared_with']['kind']

    get api_v1_metric_path('profit_margin'), headers: headers
    assert_response :bad_request
    get api_v1_metric_path('orders'), headers: bearer(['inventory:read'])
    assert_response :forbidden
    get api_v1_metrics_path
    assert_response :unauthorized
  end
end
