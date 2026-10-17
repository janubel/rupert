# frozen_string_literal: true

require 'test_helper'

class SignInLandingTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = tenants(:default_tenant)
    @user = users(:regular_user)
    Current.tenant = @tenant
    @user.update!(role: 'reporting', dashboard_config: { 'start_page' => 'bookkeeping' })
  end

  teardown { Current.reset }

  test 'password sign in honors bookkeeping preference without changing permissions' do
    sign_in_password
    assert_redirected_to books_check_path
    assert_equal @user.id, session[:user_id]
    assert_equal 'reporting', @user.reload.role
    refute @user.can?('finance.write')

    get login_path
    assert_redirected_to books_check_path
  end

  test 'bookkeeping preference cannot grant reports access or keep a revoked landing' do
    sign_in_password
    @user.update_permission_overrides!(%w[dashboard.read inventory.read])

    get login_path
    assert_redirected_to root_path
    get books_check_path
    assert_response :redirect

    delete logout_path
    sign_in_password
    assert_redirected_to root_path
    refute @user.reload.can?('reports.read')
    assert_equal 'bookkeeping', @user.dashboard_config_hash['start_page']
  end

  test 'arbitrary saved start pages never become redirect destinations' do
    @user.update!(dashboard_config: { 'start_page' => 'https://outside.example/private' })
    sign_in_password
    assert_redirected_to root_path
    get login_path
    assert_redirected_to root_path
  end

  test 'Google sign in uses the same permission checked preference' do
    sign_in_google
    assert_redirected_to books_check_path
    assert_equal @user.id, session[:user_id]
    assert_equal 'reporting', @user.reload.role

    delete logout_path
    @user.update_permission_overrides!(%w[dashboard.read inventory.read])
    sign_in_google
    assert_redirected_to root_path
    refute @user.reload.can?('reports.read')
  end

  test 'employee password and Google logins always use the personal workspace' do
    @user.update!(role: 'employee')
    # Even a historical mistaken grant cannot cross the employee boundary.
    @user.user_permissions.create!(tenant_id: @tenant.id, permission: 'reports.read', enabled: true)
    sign_in_password
    assert_redirected_to employee_app_path
    get login_path
    assert_redirected_to employee_app_path

    delete logout_path
    sign_in_google
    assert_redirected_to employee_app_path
    assert_equal 'employee', @user.reload.role
    refute @user.can?('reports.read')
  end

  test 'widget customization preserves the saved landing and ignores privilege parameters' do
    sign_in_password
    post customize_dashboard_path, params: {
      widgets: ['stats'], hidden: ['stats'], start_page: 'https://outside.example/',
      dashboard_config: { start_page: 'https://outside.example/' }, role: 'super_admin',
      permissions: ['*']
    }
    assert_response :success
    assert_equal({ 'start_page' => 'bookkeeping', 'widgets' => ['stats'], 'hidden' => ['stats'] }, @user.reload.dashboard_config_hash)
    assert_equal 'reporting', @user.role
    assert_empty @user.user_permissions
    refute @user.can?('users.write')
  end

  test 'reset clears layout without clearing the landing or changing access' do
    @user.update!(dashboard_config: { 'start_page' => 'bookkeeping', 'widgets' => ['stats'], 'hidden' => ['stats'] })
    sign_in_password
    post customize_dashboard_path, params: { reset: true, start_page: 'system', role: 'super_admin' }
    assert_response :success
    assert_equal({ 'start_page' => 'bookkeeping' }, @user.reload.dashboard_config_hash)
    assert_equal 'reporting', @user.role
    refute @user.can?('users.write')
    get login_path
    assert_redirected_to books_check_path
  end

  test 'unavailable widgets reject the whole change and preserve the landing' do
    sign_in_password
    assert_no_changes -> { @user.reload.dashboard_config } do
      post customize_dashboard_path, params: { widgets: ['people'], start_page: 'system', role: 'admin' }
    end
    assert_response :unprocessable_entity
    assert_equal 'reporting', @user.reload.role
  end

  private

  def sign_in_password
    post login_path, params: { email: @user.email, password: 'password' }
  end

  def sign_in_google
    OauthAllowedDomain.find_or_create_by!(tenant_id: @tenant.id, domain: 'example.com')
    GoogleOauthService.stubs(:auth_url).returns('https://accounts.google.com/')
    get google_auth_path
    state = session[:oauth_state]
    GoogleOauthService.expects(:exchange_code!).returns('email' => @user.email, 'sub' => 'landing-test-subject', 'name' => 'Landing test')
    get google_callback_path, params: { code: 'test-code', state: state }
  end
end
