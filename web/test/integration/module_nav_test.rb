# frozen_string_literal: true

require 'test_helper'

class ModuleNavTest < ActionDispatch::IntegrationTest
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
    EnvStore.set('SHOPIFY_CLIENT_ID', 'test-client-id')
    EnvStore.set('SHOPIFY_CLIENT_SECRET', 'test-client-secret')
    post login_path, params: { email: 'admin@example.com', password: 'password' }
  end

  teardown do
    Current.tenant = nil
    EnvStore.set('SHOPIFY_CLIENT_ID', nil)
    EnvStore.set('SHOPIFY_CLIENT_SECRET', nil)
  end

  test 'header shows module areas and the active area is highlighted' do
    get inventory_index_path
    assert_response :success
    %w[Overview Sell Stock Money Work Team System].each do |name|
      assert_select "nav[aria-label='Module areas'] a", text: name
    end
    assert_select "nav[aria-label='Module areas'] a.nav-pill-active", text: 'Stock'
  end

  test 'second bar shows the modules of the active area' do
    get inventory_index_path
    assert_response :success
    assert_select "nav[aria-label='Module'] a", text: 'Locations'
    assert_select "nav[aria-label='Module'] a", text: 'Alerts'
    assert_select "nav[aria-label='Module'] a.nav-pill-active-sm", text: 'Stock comparison'
  end

  test 'single-module areas do not render a second bar' do
    get root_path
    assert_response :success
    assert_select "nav[aria-label='Module']", count: 0
    assert_select "nav[aria-label='Module areas'] a.nav-pill-active", text: 'Overview'
  end

  test 'nav is filtered by role permissions' do
    reader = User.create!(
      email: 'reader@example.com',
      password: 'password123',
      role: 'reader',
      tenant: tenants(:default_tenant)
    )
    delete logout_path
    post login_path, params: { email: 'reader@example.com', password: 'password123' }
    assert_equal reader.id, session[:user_id]

    get ledger_index_path
    assert_response :success
    assert_select "nav[aria-label='Module areas'] a", text: 'Money'
    assert_select "nav[aria-label='Module'] a", text: 'Ledger'
    assert_select "nav[aria-label='Module'] a", text: 'Reports'
    assert_select "nav[aria-label='Module'] a", text: 'Projects', count: 0
    assert_select "nav[aria-label='Module'] a", text: 'Goals', count: 0
    assert_select "nav[aria-label='Module'] a", text: 'KPIs', count: 0
  end

  test 'Team tab links to the tenant member list' do
    get users_path
    assert_response :success
    team = assert_select("nav[aria-label='Module areas'] a", text: 'Team')
    assert_equal(users_path, team.first['href'])
    assert_select "nav[aria-label='Module'] a", text: 'Users'
    assert_select "nav[aria-label='Module'] a.nav-pill-active-sm", text: 'Users'
    assert_select "nav[aria-label='Module'] a", text: 'Users', count: 1
  end

  test "Finance Accounts module doesn't leak into the Team nav" do
    get finance_accounts_path
    assert_response :success
    assert_select "nav[aria-label='Module areas'] a", text: 'Money'
    assert_select "nav[aria-label='Module'] a", text: 'Finance overview', count: 1
    assert_select "nav[aria-label='Module'] a.nav-pill-active-sm", text: 'Finance overview'

    get users_path
    assert_response :success
    assert_select "nav[aria-label='Module'] a", text: 'Finance overview', count: 0
    assert_select "nav[aria-label='Module'] a", text: 'Users', count: 1
    assert_select "nav[aria-label='Module'] a", text: 'Employees'
  end
end
