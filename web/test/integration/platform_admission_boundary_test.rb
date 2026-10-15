# frozen_string_literal: true

require 'test_helper'

class PlatformAdmissionBoundaryTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = tenants(:default_tenant)
    @admin = users(:regular_user)
    Current.reset
  end

  teardown { Current.reset }

  test 'password sign in cannot establish a session for a suspended workspace' do
    @tenant.update!(status: 'suspended')
    post login_path, params: { email: @admin.email, password: 'password' }
    assert_response :unprocessable_entity
    assert_nil session[:user_id]
    assert_includes response.body, 'Invalid email or password'
    get root_path
    assert_redirected_to login_path
  end

  test 'suspending a workspace revokes an existing browser session beyond reactivation' do
    sign_in_admin
    @tenant.update!(status: 'suspended')
    get root_path
    assert_response :forbidden
    assert_nil session[:user_id]
    assert_includes response.body, 'This workspace is inactive'
    @tenant.update!(status: 'active')
    get root_path
    assert_redirected_to login_path
  end

  test 'an account without a home workspace cannot use its password to sign in' do
    @admin.update_column(:tenant_id, nil)
    post login_path, params: { email: @admin.email, password: 'password' }
    assert_response :unprocessable_entity
    assert_nil session[:user_id]
    get root_path
    assert_redirected_to login_path
  end

  test 'a platform owner cannot retain a session when selecting a suspended workspace' do
    owner = User.create!(tenant: @tenant, email: 'boundary-owner@example.org', password: 'password123', role: 'super_admin')
    host! 'boundary-suspended.example.org'
    post login_path, params: { email: owner.email, password: 'password123' }
    assert_equal owner.id, session[:user_id]
    selected = Tenant.create!(name: 'Suspended workspace', subdomain: 'boundary-suspended', status: 'suspended')
    get root_path
    assert_response :forbidden
    assert_nil session[:user_id]
    selected.update!(status: 'active')
    get root_path
    assert_redirected_to login_path
  end

  test 'instance navigation requires the actual active platform owner role despite permission overrides' do
    @admin.update_permission_overrides!(%w[settings.read settings.write system.read system.write])
    @admin.reload
    assert @admin.can?('system.write')
    refute_includes ModuleRegistry.nav_for(@admin).map(&:key), 'platform'
    owner = User.create!(tenant: @tenant, email: 'boundary-nav-owner@example.org', password: 'password123', role: 'super_admin')
    assert_includes ModuleRegistry.nav_for(owner).map(&:key), 'platform'
    owner.update!(active: false)
    refute_includes ModuleRegistry.nav_for(owner).map(&:key), 'platform'
  end

  test 'signup form contacts are redacted before request instrumentation' do
    captured = []
    listener = lambda do |_name, _started, _finished, _id, payload|
      captured << payload[:params] if payload[:controller] == 'SignupsController'
    end
    private_name = 'PRIVATE_INSTRUMENTATION_COMPANY'
    GoogleOauthService.stubs(:auth_url).returns('https://accounts.google.com/o/oauth2/auth')
    ActiveSupport::Notifications.subscribed(listener, 'start_processing.action_controller') do
      post signup_path, params: { workspace_signup: { workspace_name: private_name,
        domain: 'boundary-private-company.org', requested_subdomain: 'boundary-private-company' }, source: 'visible-source' }
      assert_response :redirect
    end
    assert_equal 1, captured.length
    assert_equal '[FILTERED]', captured.first['workspace_signup']
    assert_equal 'visible-source', captured.first['source']
    refute_includes captured.first.inspect, private_name
    refute_includes captured.first.inspect, 'boundary-private-company.org'
  end

  private

  def sign_in_admin
    post login_path, params: { email: @admin.email, password: 'password' }
    assert_equal @admin.id, session[:user_id]
  end
end
