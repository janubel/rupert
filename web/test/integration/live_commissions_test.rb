# frozen_string_literal: true

require 'test_helper'

class LiveCommissionsTest < ActionDispatch::IntegrationTest
  setup do
    Current.tenant = tenants(:default_tenant)
    @user = users(:regular_user)
    post login_path, params: { email: @user.email, password: 'password' }
  end
  teardown { Current.reset }

  test 'payroll reader sees uncached shift coverage and gateway limitations in a refreshable frame' do
    get live_commissions_path
    assert_response :success
    assert_equal 'no-store', response.headers['Cache-Control']
    assert_select 'turbo-frame#live-commissions'
    assert_includes response.body, 'No clock shifts are recorded today'
    assert_includes response.body, 'not added as another sale or commission'
    assert_includes response.body, '1%'
    assert_includes response.body, 'API credentials needed for live reporting'
  end

  test 'source and currency must be explicit supported values' do
    get live_commissions_path, params: { source: 'authorize_net', currency: 'USD' }
    assert_response :unprocessable_entity
    get live_commissions_path, params: { source: 'square', currency: 'CAD' }
    assert_response :success
    assert_includes response.body, 'No Square orders are imported in CAD'
  end

  test 'payroll restrictions protect live data independently from sync permission' do
    @user.update_permission_overrides!(['dashboard.read', 'sync.read'])
    get live_commissions_path
    assert_response :redirect
    refute DashboardWidget.allowed?('commissions', @user.reload)
    @user.update_permission_overrides!(['dashboard.read', 'payroll.read'])
    get live_commissions_path
    assert_response :success
    assert DashboardWidget.allowed?('commissions', @user.reload)
  end
end
