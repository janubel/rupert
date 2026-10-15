# frozen_string_literal: true

require 'test_helper'

# A store administrator manages only their own workspace: other tenants' people,
# per-person permissions and role overrides must be unreachable and unaffected.
class TenantAdminIsolationTest < ActionDispatch::IntegrationTest
  setup do
    @tenant_a = tenants(:default_tenant)
    @tenant_b = Tenant.create!(name: 'Other Co', subdomain: "other#{SecureRandom.hex(4)}")
    Current.tenant = @tenant_a
    @admin_a = User.create!(tenant: @tenant_a, email: 'admin-a@example.com', password: 'password123', role: 'admin')
    Current.tenant = @tenant_b
    @cashier_b = User.create!(tenant: @tenant_b, email: 'cashier-b@example.com', password: 'password123', role: 'cashier')
    Current.reset
    post login_path, params: { email: @admin_a.email, password: 'password123' }
    assert_redirected_to root_path
  end

  teardown { Current.reset }

  test 'employee list shows only the signed-in workspace' do
    get users_path
    assert_response :success
    assert_includes response.body, 'admin-a@example.com'
    assert_not_includes response.body, 'cashier-b@example.com'
  end

  test 'another workspaces employee cannot be opened, edited, removed or deactivated' do
    get edit_user_path(@cashier_b)
    assert_response :not_found

    patch user_path(@cashier_b), params: { user: { role: 'admin', active: '0', name: 'Hijacked' } }
    assert_response :not_found
    post deactivate_user_path(@cashier_b)
    assert_response :not_found
    post update_permission_path_for(@cashier_b), params: { permissions: { 'users.write' => '1' } }
    assert_response :not_found
    assert_no_difference('User.count') { delete user_path(@cashier_b) }
    assert_response :not_found

    @cashier_b.reload
    assert_equal 'cashier', @cashier_b.role
    assert @cashier_b.active?
    assert_not_equal 'Hijacked', @cashier_b.name
    assert_empty UserPermission.where(user_id: @cashier_b.id)
  end

  test 'a new employee always joins the signed-in workspace' do
    post users_path, params: { user: { name: 'New', email: 'new-a@example.com', password: 'password123',
      role: 'cashier', tenant_id: @tenant_b.id } }
    assert_equal @tenant_a.id, User.find_by!(email: 'new-a@example.com').tenant_id
  end

  test 'saving or resetting role permissions leaves other workspaces untouched' do
    RolePermission.create!(tenant_id: @tenant_b.id, role: 'cashier', permission: 'inventory.write', enabled: true)

    post save_permissions_path, params: { roles: { 'cashier' => { 'sales.read' => '1' } } }
    assert_redirected_to permissions_path
    assert_equal 1, RolePermission.where(tenant_id: @tenant_b.id).count
    assert_equal 1, RolePermission.where(tenant_id: @tenant_a.id).count

    post reset_permissions_path
    assert_equal 1, RolePermission.where(tenant_id: @tenant_b.id).count
    assert_equal 0, RolePermission.where(tenant_id: @tenant_a.id).count
  end

  test 'role overrides in one workspace never change another workspaces permissions' do
    RolePermission.create!(tenant_id: @tenant_b.id, role: 'cashier', permission: 'inventory.write', enabled: true)
    cashier_a = User.create!(tenant: @tenant_a, email: 'cashier-a@example.com', password: 'password123', role: 'cashier')

    assert cashier_a.can?('sales.read'), 'built-in cashier permissions apply in workspace A'
    assert @cashier_b.can?('inventory.write')
    assert_not @cashier_b.can?('sales.read'), 'workspace B override replaces the defaults only there'
  end

  test 'workspace settings and feature flags are keyed per tenant' do
    Current.tenant = @tenant_b
    TenantSettings.set(:business_name, 'Other Co Ltd')
    FeatureFlag.set(:fulfillment_workflow, true)
    Current.tenant = @tenant_a
    assert_not_equal 'Other Co Ltd', TenantSettings.business_name
    assert_not FeatureFlag.enabled?(:fulfillment_workflow)
  end

  private

  def update_permission_path_for(user)
    "/users/#{user.id}/update_permissions"
  end
end
