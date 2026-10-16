# frozen_string_literal: true

require 'test_helper'

class EmployeeConsolidationIntegrationTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:regular_user)
    Current.tenant = @user.tenant
    @primary = People::Employee.create!(first_name: 'Alex', last_name: 'Worker')
    @duplicate = People::Employee.create!(first_name: 'Alex', last_name: 'Worker')
    @duplicate.source_identities.create!(source: 'square', external_id: 'team-test', first_name: 'Alex', last_name: 'Worker', source_active: true)
    post login_path, params: { email: @user.email, password: 'password' }
  end
  teardown { Current.reset }

  test 'administrator can consolidate and old employee bookmarks redirect to canonical profile' do
    get consolidation_people_employees_path
    assert_response :success
    post consolidate_people_employees_path, params: { primary_id: @primary.id, duplicate_ids: [@duplicate.id], reason: 'Confirmed identity' }
    assert_redirected_to people_employee_path(@primary)
    get people_employee_path(@duplicate)
    assert_redirected_to people_employee_path(@primary)
    get people_employees_path(source: 'square')
    assert_response :success
    assert_select 'a', text: 'Alex Worker', count: 1
    get people_employee_path(@primary)
    assert_select 'h2', 'Linked app profiles'
  end

  test 'manager with HR permission cannot merge accounts without account management permission' do
    @user.update!(role: 'manager')
    post consolidate_people_employees_path, params: { primary_id: @primary.id, duplicate_ids: [@duplicate.id], reason: 'Confirmed' }
    Current.tenant = @user.tenant
    assert_nil @duplicate.reload.merged_into_id
  end

  test 'fresh employee setup renders the linked account and completes web login' do
    @primary.update!(email: 'new-employee-consolidation@example.com')
    post employee_access_path(employee_id: @primary.id)
    assert_response :success
    assert_select '#setup-link'
    assert_equal 'no-store', response.headers['Cache-Control']
    link = css_select('#setup-link').first['value']
    token = URI.decode_www_form(URI(link).query).to_h.fetch('token')
    assert_equal @primary.email, @primary.reload.user.email
    delete logout_path
    get employee_setup_path, params: { token: token }
    assert_response :success
    patch employee_setup_path, params: { token: token, password: 'employee-password123', password_confirmation: 'employee-password123' }
    assert_redirected_to employee_app_path
    get people_timesheets_path
    assert_response :success
    get employee_setup_path, params: { token: token }
    assert_response :gone
  end
end
