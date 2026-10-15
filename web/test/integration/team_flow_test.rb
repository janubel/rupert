# frozen_string_literal: true

require 'test_helper'

class TeamFlowTest < ActionDispatch::IntegrationTest
  module TestShopifySession
    def current_shopify_session
      @test_session ||= ShopifyAPI::Auth::Session.new(
        shop: 'm11u0i-sb.myshopify.com',
        access_token: 'test-token',
        is_online: false,
        expires: Time.now + 3600
      )
    end
  end

  ShopifyApp::TokenExchange.prepend(TestShopifySession)

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

    @tenant = Tenant.create!(name: 'Test Co', subdomain: 'testco')
    @admin = User.create!(
      email: 'boss@example.com',
      password: 'password123',
      role: 'admin',
      tenant_id: @tenant.id,
      name: 'Boss'
    )
    post login_path, params: { email: 'boss@example.com', password: 'password123' }
    Current.tenant = @tenant
  end

  teardown do
    Current.tenant = nil
  end

  def get_page(path)
    get(path, params: { shop: 'm11u0i-sb.myshopify.com', embedded: '1', host: 'test-host' })
  end

  test 'employee accounts index lists the team' do
    get_page users_path
    assert_response :success
    assert_select 'h1', /Employee accounts/
    assert_select 'td', /Boss/
  end

  test 'create an employee and assign a role' do
    User.create!(email: 'root@example.com', password: 'password123', role: 'super_admin', tenant_id: @tenant.id,
      name: 'Root')
    host! 'testco.example.com' # super_admin resolves the tenant via subdomain
    delete logout_path
    post login_path, params: { email: 'root@example.com', password: 'password123' }

    get_page new_user_path
    assert_response :success

    post users_path, params: {
      user: { name: 'Jamie Rivera', email: 'jamie@example.com', role: 'cashier', password: 'password123' },
      shop: 'm11u0i-sb.myshopify.com',
      embedded: '1'
    }
    follow_redirect!
    assert_response :success

    employee = User.find_by!(email: 'jamie@example.com')
    assert_equal 'cashier', employee.role
    assert employee.active?
    assert_select 'td', /Jamie Rivera/
  end

  test 'a non-super-admin cannot escalate to super_admin' do
    User.create!(email: 'mid@example.com', password: 'password123', role: 'admin', tenant_id: @tenant.id,
      name: 'Mid')
    delete logout_path
    post login_path, params: { email: 'mid@example.com', password: 'password123' }

    post users_path, params: {
      user: { name: 'Sneaky', email: 'sneaky@example.com', role: 'super_admin', password: 'password123' },
      shop: 'm11u0i-sb.myshopify.com',
      embedded: '1'
    }
    follow_redirect!
    assert_response :success

    assert_nil User.find_by(email: 'sneaky@example.com')
    assert_match(/allowed employee role/, flash[:alert])
  end

  test 'deactivated employee cannot sign in' do
    employee = User.create!(
      email: 'reader@example.com',
      password: 'password123',
      role: 'reader',
      tenant_id: @tenant.id,
      name: 'Reader'
    )

    post deactivate_user_path(employee), params: { shop: 'm11u0i-sb.myshopify.com', embedded: '1' }
    follow_redirect!
    assert_response :success
    assert_equal false, employee.reload.active?

    delete logout_path
    post login_path, params: { email: 'reader@example.com', password: 'password123' }
    assert_response :unprocessable_content
    assert_select 'body', /Invalid email or password/
  end

  test 'permissions screen shows the matrix and saves overrides' do
    get_page permissions_path
    assert_response :success
    assert_select 'h1', /Permissions/
    assert_select 'input[type=checkbox]'

    post save_permissions_path, params: {
      roles: { 'cashier' => { 'sales.read' => '1', 'customers.read' => '1' } },
      shop: 'm11u0i-sb.myshopify.com',
      embedded: '1'
    }
    follow_redirect!
    assert_response :success

    overrides = RolePermission.where(tenant_id: @tenant.id, role: 'cashier')
    assert_equal ['customers.read', 'sales.read'], overrides.order(:permission).pluck(:permission).sort

    cashier = User.new(role: 'cashier', tenant_id: @tenant.id)
    assert cashier.can?('sales.read')
    refute cashier.can?('inventory.read') # no longer in built-in cashier defaults
  end

  test 'per-employee overrides layer on top of the role' do
    employee = User.create!(
      email: 'cashier@example.com',
      password: 'password123',
      role: 'cashier',
      tenant_id: @tenant.id,
      name: 'Cashier'
    )

    get_page edit_user_path(employee)
    assert_response :success
    assert_select 'h2', /Per-person permissions/

    post update_permissions_user_path(employee), params: {
      permissions: { 'sales.read' => '1', 'ledger.read' => '1' },
      shop: 'm11u0i-sb.myshopify.com',
      embedded: '1'
    }
    follow_redirect!
    assert_response :success

    employee.reload
    assert employee.can?('sales.read')
    assert employee.can?('ledger.read')
    refute employee.can?('inventory.read') # override drops built-in cashier access
    assert employee.permission_overrides?

    # Clearing returns to role defaults
    post update_permissions_user_path(employee), params: {
      permissions: {},
      shop: 'm11u0i-sb.myshopify.com',
      embedded: '1'
    }
    follow_redirect!
    employee.reload
    refute employee.permission_overrides?
    assert employee.can?('customers.read') # back to built-in cashier defaults
  end

  test 'reset permissions clears overrides' do
    RolePermission.create!(tenant_id: @tenant.id, role: 'cashier', permission: 'sales.read')

    post reset_permissions_path, params: { shop: 'm11u0i-sb.myshopify.com', embedded: '1' }
    follow_redirect!
    assert_response :success
    assert_equal 0, RolePermission.where(tenant_id: @tenant.id).count
  end
end
