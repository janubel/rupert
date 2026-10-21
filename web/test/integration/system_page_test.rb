# frozen_string_literal: true

require 'test_helper'

class SystemPageTest < ActionDispatch::IntegrationTest
  setup do
    ShopifyAPI::Context.setup(
      api_key: 'test-key',
      api_secret_key: 'test-secret',
      api_version: ShopifyAPI::AdminVersions::SUPPORTED_ADMIN_VERSIONS.first,
      host_name: 'localhost',
      scope: 'read_products',
      is_private: false,
      is_embedded: false
    )
    Shop.create!(shopify_domain: 'm11u0i-sb.myshopify.com', shopify_token: 'test-token')
    Current.tenant = tenants(:default_tenant)
    post login_path, params: { email: 'admin@example.com', password: 'password' }
  end

  teardown { Current.tenant = nil }

  test 'super admin can view system health' do
    users(:regular_user).update!(role: 'super_admin')
    get system_path
    assert_response :success
    assert_select 'h1', /System health/
    assert_select 'p', /Load average|Memory|Swap|Disk/
    assert_select 'h2', %r{Web server|Background jobs|Database}
  end

  test 'store admin cannot view instance diagnostics despite the system permission' do
    assert users(:regular_user).can?('system.read')
    get system_path
    assert_redirected_to root_path
    assert_match(/don't have permission/, flash[:alert])
  end

  test 'reader cannot view system health' do
    User.create!(
      email: 'sysreader@example.com',
      password: 'password123',
      role: 'reader',
      tenant: tenants(:default_tenant)
    )
    delete logout_path
    post login_path, params: { email: 'sysreader@example.com', password: 'password123' }

    get system_path
    assert_redirected_to root_path
    assert_match(/don't have permission/, flash[:alert])
  end

  test 'system presenter collects metrics' do
    presenter = SystemPresenter.new
    assert presenter.cpu_count.positive?
    assert presenter.mem_total_mb.positive?
    assert presenter.disk_used_pct >= 0
    assert presenter.db_max_connections.positive?
    assert presenter.sync_success_rate >= 0
  end
end
