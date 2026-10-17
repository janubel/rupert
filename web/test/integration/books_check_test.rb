# frozen_string_literal: true

require 'test_helper'

class BooksCheckIntegrationTest < ActionDispatch::IntegrationTest
  setup do
    Current.tenant = tenants(:default_tenant)
    post login_path, params: { email: 'admin@example.com', password: 'password' }
  end

  teardown { Current.tenant = nil }

  test 'page renders for a signed-in reviewer and exports csv' do
    get books_check_path
    assert_response :success
    assert_select 'h1', 'Books check'
    assert_equal 'private, no-store', response.headers['Cache-Control']
    get books_check_path(format: :csv)
    assert_response :success
    assert_equal 'text/csv', response.media_type
  end

  test 'requires sign in' do
    delete logout_path
    get books_check_path
    assert_redirected_to login_path
  end

  test 'financial report warns about refunded orders with no refund record' do
    tenant = tenants(:default_tenant)
    order = Core::Order.new(source: 'shopify', source_order_id: 'r1', order_number: 'R1', channel: 'online',
      gross_cents: 6360, tax_cents: 0, occurred_at: 1.day.ago, tenant_id: tenant.id)
    order.mark_paid!
    order.refund!
    order.save!
    get financial_reports_path
    assert_response :success
    assert_select '[role=alert]', /no refund amount recorded/
  end

  test 'sales without a location still appear as Unassigned' do
    tenant = tenants(:default_tenant)
    order = Core::Order.new(source: 'shopify', source_order_id: 'u1', channel: 'online', gross_cents: 4200,
      tax_cents: 0, occurred_at: 1.day.ago, tenant_id: tenant.id)
    order.mark_paid!
    order.save!
    get sales_reports_path
    assert_response :success
    assert_includes response.body, 'Unassigned'
  end
end
