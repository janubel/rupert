# frozen_string_literal: true

require 'test_helper'

class CustomerPaginationTest < ActionDispatch::IntegrationTest
  test 'customers with identical timestamps paginate consistently within their tenant' do
    Current.tenant = tenants(:default_tenant)
    customers = Array.new(26) do |number|
      Core::Customer.create!(source: 'manual', external_id: "pagination-#{number}", first_name: "Customer #{number}",
        created_at: Time.zone.parse('2026-10-01 12:00:00'))
    end
    other = Tenant.create!(name: 'Other store', subdomain: 'pagination-other')
    Core::Customer.create!(source: 'manual', external_id: 'other-customer', first_name: 'Other tenant',
      tenant: other, created_at: Time.zone.parse('2026-10-01 12:00:00'))
    post login_path, params: { email: 'admin@example.com', password: 'password' }

    get customers_path
    assert_response :success
    first_page = css_select('tbody a').map { |link| link['href'] }
    assert_equal customers.reverse.first(25).map { |customer| customer_path(customer) }, first_page

    get customers_path, params: { page: 2 }
    assert_response :success
    assert_equal [customer_path(customers.first)], css_select('tbody a').map { |link| link['href'] }
  ensure
    Current.reset
  end
end
