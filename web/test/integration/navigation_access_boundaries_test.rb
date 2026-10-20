# frozen_string_literal: true

require 'test_helper'

class NavigationAccessBoundariesTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = tenants(:default_tenant)
    @user = users(:regular_user)
    Current.tenant = @tenant
    EnvStore.set('SHOPIFY_CLIENT_ID', 'test-client-id')
    EnvStore.set('SHOPIFY_CLIENT_SECRET', 'test-client-secret')
    post login_path, params: { email: @user.email, password: 'password' }
  end

  teardown { Current.reset }

  test 'reader excludes personnel and manager payroll requires an explicit grant' do
    @user.update!(role: 'reader')
    %w[hr.read timesheets.read leave.read payroll.read].each { |permission| refute @user.reload.can?(permission) }
    @user.update!(role: 'manager')
    refute @user.reload.can?('payroll.read')
    assert @user.can?('hr.read')
    @user.update_permission_overrides!(%w[hr.read payroll.read])
    assert @user.reload.can?('payroll.read')
  end

  test 'memoized role permissions clear on role and explicit permission changes' do
    assert @user.can?('payroll.read')
    @user.update!(role: 'reader')
    refute @user.can?('payroll.read')
    @user.update_permission_overrides!(%w[dashboard.read payroll.read])
    assert @user.can?('payroll.read')
    @user.update_permission_overrides!(%w[dashboard.read])
    refute @user.can?('payroll.read')
  end

  test 'employee account and organization associations cannot cross workspaces' do
    Current.tenant = @tenant
    other = Tenant.create!(name: 'Other workspace', subdomain: 'other-associations')
    foreign_user = User.create!(tenant: other, email: 'foreign-association@example.com', password: 'password123', role: 'reader')
    foreign_department = People::Department.create!(tenant: other, name: 'Foreign department')
    foreign_position = People::Position.create!(tenant: other, name: 'Foreign position')
    attributes = { first_name: 'Own', last_name: 'Employee', user_id: foreign_user.id,
      department_id: foreign_department.id, position_id: foreign_position.id }
    assert_no_difference('People::Employee.count') do
      post people_employees_path, params: { employee: attributes }
    end
    assert_response :unprocessable_entity
    assert_includes response.body, 'must belong to this workspace'
    own = People::Employee.create!(first_name: 'Own', last_name: 'Employee')
    patch people_employee_path(own), params: { employee: attributes }
    assert_response :unprocessable_entity
    assert_nil own.reload.user_id
    assert_nil own.department_id
    assert_nil own.position_id
  end

  test 'dashboard direct URLs and layout mutation require dashboard access' do
    grant('inventory.read')
    get dashboard_path
    assert_response :forbidden
    assert_no_changes -> { @user.reload.dashboard_config } do
      post customize_dashboard_path, params: { widgets: ['stats'] }
    end
    assert_response :forbidden
  end

  test 'dashboard only queries and renders authorized categories after cached revocation' do
    with_memory_cache do
      get dashboard_path
      assert_response :success
      assert_select '[data-widget-key=revenue]'
      assert_select 'input[value="Sync now"]'

      grant('dashboard.read', 'inventory.read')
      Core::Order.expects(:where).never
      People::Employee.expects(:active).never
      get dashboard_path
      assert_response :success
      assert_select '[data-widget-key=stats]'
      assert_select '[data-widget-key=revenue]', count: 0
      assert_select '[data-widget-key=people]', count: 0
      assert_select '[data-widget-key=sync_history]', count: 0
      assert_select 'input[value="Sync now"]', count: 0
      assert_select '.stat-label', text: /Today's sales/, count: 0
      assert_select '.stat-label', text: /Website products/

      post customize_dashboard_path, params: { widgets: ['revenue'] }
      assert_response :unprocessable_entity
    end
  end

  test 'global search checks every module permission and invalidates cached results on revocation' do
    Current.tenant = @tenant
    Core::Customer.create!(source: 'shopify', external_id: 'access-search', first_name: 'Accessneedle')
    Core::Order.create!(source: 'shopify', source_order_id: 'access-search', order_number: 'ACCESSNEEDLE',
      channel: 'online', gross_cents: 123_400, occurred_at: Time.current)
    product = ShopifyProduct.create!(id: 'access-search-product', title: 'Private product')
    ShopifyVariant.create!(id: 'access-search-variant', productId: product.id, title: 'Needle', sku: 'ACCESSNEEDLE')
    People::Employee.create!(first_name: 'Accessneedle', last_name: 'Private')
    with_memory_cache do
      get search_path, params: { q: 'accessneedle' }
      assert_response :success
      assert_equal %w[customer employee order sku], response.parsed_body.map { |row| row['type'] }.sort
      %w[sales.read customers.read inventory.read hr.read].zip(%w[order customer sku employee]).each do |permission, type|
        grant('dashboard.read', permission)
        get search_path, params: { q: 'accessneedle' }
        assert_response :success
        assert_equal [type], response.parsed_body.map { |row| row['type'] }
      end
      grant('dashboard.read')
      get search_path, params: { q: 'accessneedle' }
      assert_equal [], response.parsed_body
    end
  end

  test 'HR directory access does not imply payroll leave or timesheet access' do
    Current.tenant = @tenant
    employee = People::Employee.create!(first_name: 'Private', last_name: 'Compensation', email: 'hr@example.com')
    rate = People::PayRate.create!(employee: employee, pay_type: 'hourly', hourly_rate_cents: 9876,
      effective_on: Date.current)
    run = People::PayRun.create!(name: 'Sensitive payroll evidence', period_start: Date.current - 7, period_end: Date.current)
    People::Payslip.create!(employee: employee, pay_rate: rate, pay_run: run, hours: 8, gross_cents: 79008, net_cents: 70000)
    grant('dashboard.read', 'hr.read')
    queries = []
    subscriber = ->(_name, _start, _finish, _id, payload) { queries << payload[:sql] }
    ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record') { get people_employee_path(employee) }
    refute queries.any? { |sql| sql.match?(/FROM ["`]?((pay_rates)|(payslips)|(timesheets)|(leave_balances)|(leave_requests))["`]?/i) }
    assert_response :success
    assert_select 'h1', employee.name
    refute_includes response.body, '$98.76'
    refute_includes response.body, 'Sensitive payroll evidence'
    %w[Recent\ timesheets Recent\ pay Pay\ rates Leave\ balances PTO\ remaining].each do |label|
      refute_includes response.body, label
    end
    grant('dashboard.read', 'hr.read', 'payroll.read')
    get people_employee_path(employee)
    assert_response :success
    assert_includes response.body, '$98.76'
    assert_includes response.body, 'Sensitive payroll evidence'
    refute_includes response.body, 'Recent timesheets'
  end

  test 'delegating users write cannot promote self or change permission matrix' do
    @user.update!(role: 'reader')
    grant('dashboard.read', 'users.read', 'users.write')
    patch user_path(@user), params: { user: { role: 'admin' } }
    assert_redirected_to root_path
    assert_equal 'reader', @user.reload.role
    assert_no_difference('UserPermission.count') do
      post update_permissions_user_path(@user), params: { permissions: { 'settings.write' => '1' } }
    end
    assert_no_difference('RolePermission.count') do
      post save_permissions_path, params: { roles: { reader: { 'settings.write' => '1' } } }
    end
    assert_redirected_to root_path
    get users_path
    assert_response :success
    assert_select 'a[href=?]', new_user_path, count: 0
    assert_select 'button', text: 'Deactivate', count: 0
    get edit_user_path(@user)
    assert_response :success
    assert_select 'form[action=?]', user_path(@user), count: 0
    get permissions_path
    assert_response :success
    assert_select 'input[type=submit][value="Save permissions"]', count: 0
    assert_select 'input[type=checkbox]:not([disabled])', count: 0
  end

  test 'settings readers never receive secret values or mutation controls' do
    Current.tenant = @tenant
    EnvStore.set('GOOGLE_OAUTH_CLIENT_SECRET', 'private-html-sentinel')
    get settings_path
    assert_response :success
    refute_includes response.body, 'private-html-sentinel'
    assert_select 'input[name=client_secret][value=""]'
    grant('dashboard.read', 'settings.read')
    get settings_path
    assert_response :success
    refute_includes response.body, 'private-html-sentinel'
    assert_select 'form[action=?]', oauth_credentials_settings_path, count: 0
    assert_select 'form[action=?]', tenant_settings_path, count: 0
    assert_select 'form[data-settings-target=envForm]', count: 0
    assert_select 'a[href=?]', backup_settings_path, count: 0
    assert_select 'input[data-settings-target=restoreFile]', count: 0
    assert_select 'form[action=?]', buzz_generate_settings_path, count: 0
    post oauth_credentials_settings_path, params: { client_secret: 'replacement' }
    assert_redirected_to root_path
    Current.tenant = @tenant
    assert_equal 'private-html-sentinel', EnvStore.fetch('GOOGLE_OAUTH_CLIENT_SECRET')
  end

  test 'blank Google secret retains it and explicit removal clears it' do
    Current.tenant = @tenant
    EnvStore.set('GOOGLE_OAUTH_CLIENT_SECRET', 'private-html-sentinel')
    post oauth_credentials_settings_path, params: { client_id: 'new-id', client_secret: '  ' }
    assert_redirected_to settings_path
    Current.tenant = @tenant
    assert_equal 'private-html-sentinel', EnvStore.fetch('GOOGLE_OAUTH_CLIENT_SECRET')
    post oauth_credentials_settings_path, params: { clear_client_secret: '1', client_secret: '' }
    assert_redirected_to settings_path
    Current.tenant = @tenant
    assert_nil EnvStore.fetch('GOOGLE_OAUTH_CLIENT_SECRET')
  end

  test 'host diagnostics cannot be delegated to a store admin or employee' do
    get system_path
    assert_redirected_to root_path
    @user.update!(role: 'reader')
    grant('dashboard.read', 'system.read', 'system.write')
    get system_path
    assert_redirected_to root_path
    @user.update!(role: 'super_admin')
    get system_path
    assert_response :success
  end

  private

  def grant(*permissions)
    @user.update_permission_overrides!(permissions)
  end

  def with_memory_cache
    previous_cache = Rails.cache
    previous_caching = ActionController::Base.perform_caching
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    ActionController::Base.perform_caching = true
    yield
  ensure
    Rails.cache = previous_cache
    ActionController::Base.perform_caching = previous_caching
  end
end
