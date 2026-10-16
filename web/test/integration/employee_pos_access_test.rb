# frozen_string_literal: true

require 'test_helper'

class EmployeePosAccessTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    @user = User.create!(tenant: @tenant, email: 'pos-worker@example.com', password: 'password123')
    @worker = People::Employee.create!(first_name: 'POS', last_name: 'Worker', user: @user)
    @location = Location.create!(source: 'ctrax', externalId: 'pos-access/7', name: 'POS access fixture')
    CtraxStockSnapshot.create!(location: @location, api_origin: 'https://fixture.api.cannatrax.net', store_id: '7', captured_at: Time.current,
      records_json: [{ 'id' => '3', 'name' => 'Tea Tin', 'product_name' => 'Tea', 'price_cents' => 1235, 'quantity' => '10', 'manage_stock' => true, 'listed' => true }])
    post login_path, params: { email: @user.email, password: 'password123' }
  end

  teardown { Current.reset }

  test 'employee can pair quote confirm and complete demo POS without access to company modules' do
    assert_equal 'employee', @user.role
    assert @user.can_use_pos?
    get ctrax_pos_path
    assert_response :success
    assert_select 'nav[aria-label="My workspace"] a[href=?]', ctrax_pos_path
    [ctrax_days_path, pos_connection_path('ctrax'), pos_setting_path(@location.id), new_sales_pos_session_path].each do |path|
      assert_select 'a[href=?]', path, count: 0
    end
    assert_equal %w[ctrax_pos time_clock timesheets], ModuleRegistry.nav_for(@user).map(&:key)
    get root_path
    assert_redirected_to ctrax_pos_path
    post pos_displays_path, params: { location_id: @location.id, demo: '1' }
    display = PosDisplaySession.last
    assert display.active?
    post quote_ctrax_pos_path(@location.id, display_id: display.id), params: { items: [{ variant_id: '3', quantity: 2 }] }, as: :json
    assert_response :success
    assert_equal '24.7', response.parsed_body['subtotal']
    display.reload
    post customer_display_tip_path, params: { display_token: display.display_token, cart_revision: display.cart_revision, choice: 'none' }, as: :json
    assert_response :success
    assert_no_difference ['Core::Order.count', 'Core::Payment.count', 'PosStockAllocation.count'] do
      post pos_checkouts_path, params: { display_id: display.id, tender: 'cash', cash_received: '100.00' }, as: :json
      assert_response :success
    end
    get pos_checkout_path(PosCheckout.last)
    assert_response :success
    assert_includes response.body, 'Demo receipt'
    get people_timesheets_path
    assert_response :success
    get time_clock_path
    assert_response :success
  end

  test 'direct URLs exports mutations and leaked generic tokens cannot expand employee access' do
    @user.update!(role: 'admin')
    token, secret = ApiAccessToken.issue(attributes: { name: 'Old business token', scopes: ['roadmap:read', 'inventory:read'] }, user: @user, tenant: @tenant)
    assert token.persisted?
    @user.update!(role: 'employee')
    @user.user_permissions.create!(tenant_id: @tenant.id, permission: '*', enabled: true)
    RolePermission.create!(tenant_id: @tenant.id, role: 'employee', permission: '*', enabled: true)
    assert @user.reload.can_use_pos?
    %w[/reports /sales /sales.csv /inventory /customers /users /permissions /settings /platform /system /syncs /roadmap /owner_checklists /search /people/employees /people/pay_runs /daily_reconciliations /financial_close /ctrax_days /sales/pos_sessions /onboarding /tenants /api_access_tokens].each do |path|
      get path, params: { user_id: users(:regular_user).id, employee_id: @worker.id }
      assert_includes [302, 303, 403, 404], response.status, path
      get path, as: :json
      assert_includes [403, 404], response.status, path
    end
    assert_no_difference ['ApiAccessToken.unscoped.count', 'UserPermission.count'] do
      post api_access_tokens_path, params: { api_access_token: { name: 'Forbidden', scopes: ['roadmap:read'] } }, as: :json
      assert_response :forbidden
      post update_permissions_user_path(@user), params: { permissions: { '*' => '1' } }, as: :json
      assert_response :forbidden
    end
    %w[/api/v1/catalog /api/v1/inventory /api/v1/roadmap].each do |path|
      get path, headers: { 'Authorization' => "Bearer #{secret}" }
      assert_response :unauthorized
    end
  end

  test 'employee cannot take over another cashiers display and deactivation closes their customer screen' do
    other = users(:regular_user)
    display = PosDisplaySession.create!(user: other, location: @location, demo: true)
    get pos_display_path(display)
    assert_response :not_found
    post clear_pos_display_path(display)
    assert_response :not_found
    post pos_checkouts_path, params: { display_id: display.id, tender: 'cash', cash_received: '100' }, as: :json
    assert_response :not_found
    own = PosDisplaySession.create!(user: @user, location: @location, demo: true)
    @user.update!(active: false)
    assert_not own.reload.active?
    get customer_display_state_path(display_token: own.display_token)
    assert_response :gone
    get ctrax_pos_path
    assert_redirected_to login_path
  end
end
