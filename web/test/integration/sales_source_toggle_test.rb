# frozen_string_literal: true

require 'test_helper'

class SalesSourceToggleTest < ActionDispatch::IntegrationTest
  setup do
    travel_to Time.zone.local(2026, 10, 16, 12)
    @tenant = tenants(:default_tenant)
    @admin = User.create!(email: 'sales-admin@example.com', password: 'password123', role: 'admin', name: 'Admin',
      tenant_id: @tenant.id)
    post login_path, params: { email: @admin.email, password: 'password123' }
    Current.tenant = @tenant
  end

  teardown do
    travel_back
    Current.tenant = nil
  end

  test 'sales page shows a source toggle with all available sources' do
    Core::Order.create!(source: 'shopify', source_order_id: 's1', occurred_at: Time.current - 1.hour,
      gross_cents: 1000, order_number: 'S1', tenant_id: @tenant.id)
    Core::Order.create!(source: 'square', source_order_id: 'sq1', occurred_at: Time.current - 1.hour,
      gross_cents: 2000, order_number: 'SQ1', tenant_id: @tenant.id)

    get sales_path
    assert_response :success
    assert_includes response.body, '>All<'
    assert_includes response.body, '>Shopify<'
    assert_includes response.body, '>Square<'
  end

  test 'the toggle filters the daily breakdown by source' do
    Core::Order.create!(source: 'shopify', source_order_id: 's1', occurred_at: Time.current - 1.hour,
      gross_cents: 1000, order_number: 'S1', tenant_id: @tenant.id)
    Core::Order.create!(source: 'square', source_order_id: 'sq1', occurred_at: Time.current - 1.hour,
      gross_cents: 2000, order_number: 'SQ1', tenant_id: @tenant.id)

    get sales_path, params: { source: 'square' }
    assert_response :success
    assert_includes response.body, 'SQ1'
    assert_not_includes response.body, 'S1'
  end

  test 'hourly by location table titles each location column even with no 9am sales' do
    location = Location.create!(source: 'square', externalId: 'loc-1', name: 'Front Counter', tenant_id: @tenant.id)
    Core::Order.create!(source: 'square', source_order_id: 'sq2', occurred_at: Time.current.change(hour: 11),
      gross_cents: 2000, order_number: 'SQ2', location_id: location.externalId, tenant_id: @tenant.id)

    get sales_path
    assert_response :success
    assert_includes response.body, 'Hourly × location'
    assert_select 'th', /Front Counter/
    assert_select 'th', /Day total/
  end
end
