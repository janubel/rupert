# frozen_string_literal: true

require 'test_helper'

class EmployeeFinancialAccessTest < ActionDispatch::IntegrationTest
  setup do
    Current.tenant = tenants(:default_tenant)
    @employee_user = User.create!(tenant: Current.tenant, email: 'employee-private-time@example.com', role: 'employee', password: 'password123')
    @employee = People::Employee.create!(first_name: 'Private', last_name: 'Employee', user: @employee_user)
  end
  teardown { Current.reset }

  test 'employee role ignores dangerous person and role overrides on financial routes and navigation' do
    %w[* sales.read sales.write reports.read reconcile.read payroll.read users.write inventory.read].each do |permission|
      @employee_user.user_permissions.create!(tenant_id: @employee_user.tenant_id, permission: permission, enabled: true)
      RolePermission.create!(tenant_id: @employee_user.tenant_id, role: 'employee', permission: permission, enabled: true)
    end
    assert_equal %w[pos.use timesheets.self tasks.self], @employee_user.reload.effective_permissions
    %w[sales.read reports.read reconcile.read inventory.read users.write].each { |permission| refute @employee_user.can?(permission) }
    refute @employee_user.can_manage_accounts?
    post login_path, params: { email: @employee_user.email, password: 'password123' }
    assert_redirected_to employee_app_path
    get people_timesheets_path
    assert_response :success
    assert_select 'a[href=?]', sales_path, count: 0
    assert_select 'a[href=?]', daily_reconciliations_path, count: 0
    %w[/sales /sales.csv /sales/print /reports /reports/sales /reports/reconciliation /reconcile /money_reconciliations /ledger /swipesimple_reports /daily_reconciliations /financial_close /cash_forecast /reconciliation_documents /reconciliation_follow_ups /customers /users /permissions /finance/accounts /finance/chart_of_accounts /people/pay_runs /people/employees /api_access_tokens /].each do |path|
      get path
      assert_includes [302, 303, 403, 404], response.status, "Employee could read #{path}"
    end
    assert_no_difference 'ApiAccessToken.unscoped.count' do
      post api_access_tokens_path, params: { api_access_token: { name: 'Forbidden', scopes: ['inventory:read'] } }
    end
  end

  test 'permission editors cannot store broader employee overrides and show the fixed boundary' do
    admin = users(:regular_user)
    post login_path, params: { email: admin.email, password: 'password' }
    get edit_user_path(@employee_user)
    assert_response :success
    assert_select 'h2', 'Staff-only access'
    assert_select 'input[name="permissions[sales.read]"]', count: 0
    post update_permissions_user_path(@employee_user), params: { permissions: { 'sales.read' => '1', 'reports.read' => '1' } }
    assert_redirected_to edit_user_path(@employee_user)
    assert_empty @employee_user.user_permissions.reload
    post save_permissions_path, params: { roles: { employee: { 'sales.read' => '1', 'reconcile.read' => '1' } } }
    assert_empty RolePermission.where(tenant_id: admin.tenant_id, role: 'employee')
    assert_raises(ArgumentError) { @employee_user.update_permission_overrides!(['sales.read']) }
  end

  test 'employee app bearer remains scoped to self-service APIs' do
    post '/api/v1/employee/session', params: { email: @employee_user.email, password: 'password123' }, as: :json
    assert_response :created
    token = response.parsed_body.fetch('token')
    headers = { 'Authorization' => "Bearer #{token}" }
    get '/api/v1/employee/timesheets', headers: headers
    assert_response :success
    get '/api/v1/employee/clock', headers: headers
    assert_response :success
    %w[/api/v1/catalog /api/v1/inventory /api/v1/roadmap].each do |path|
      get path, headers: headers
      assert_response :unauthorized
    end
    get '/reports/sales', headers: headers
    assert_redirected_to login_path
    post '/api/v1/employee/session', params: { email: @employee_user.email, password: 'password123' }, as: :json
    assert_response :created
    @employee_user.update!(active: false)
    get '/api/v1/employee/timesheets', headers: headers
    assert_response :unauthorized
  end

  test 'privileged administrators retain their explicit business access' do
    [users(:regular_user), User.create!(tenant: Current.tenant, email: 'platform-financial-owner@example.com', role: 'super_admin', password: 'password123')].each do |admin|
      assert admin.can?('sales.read')
      assert admin.can?('reports.read')
      assert admin.can?('reconcile.read')
      assert admin.can_manage_accounts?
    end
  end
end
