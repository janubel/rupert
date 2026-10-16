# frozen_string_literal: true

require 'test_helper'

class EmployeeDirectoryPaginationTest < ActionDispatch::IntegrationTest
  test 'all source employees paginate and login readiness filters retain their scope' do
    Current.tenant = tenants(:default_tenant)
    52.times do |n|
      People::Employee.create!(first_name: 'Directory', last_name: format('Person %03d', n), employment_type: 'unspecified', source: 'square', external_id: "roster-#{n}")
    end
    other = Tenant.create!(name: 'Foreign roster', subdomain: 'foreign-roster')
    People::Employee.create!(tenant: other, first_name: 'Foreign', last_name: 'Employee', employment_type: 'unspecified', source: 'square', external_id: 'roster-0')
    post login_path, params: { email: 'admin@example.com', password: 'password' }
    get people_employees_path, params: { source: 'square', login: 'missing' }
    assert_response :success
    assert_select 'tbody tr', count: 50
    first = css_select('tbody a').map { |a| a['href'] }
    get people_employees_path, params: { source: 'square', login: 'missing', page: 2 }
    assert_response :success
    assert_select 'tbody tr', count: 2
    second = css_select('tbody a').map { |a| a['href'] }
    assert_empty first & second
    assert_equal 52, (first + second).uniq.size
    refute_includes response.body, 'Foreign Employee'
    get people_employees_path, params: { source: 'square', login: 'linked' }
    assert_response :success
    assert_select 'tbody a', count: 0
  ensure
    Current.reset
  end
end
