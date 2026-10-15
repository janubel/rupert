# frozen_string_literal: true

require 'test_helper'

class EmployeeRoleBoundariesTest < ActionDispatch::IntegrationTest
  teardown { Current.reset }

  test 'store admin creates the selected employee role instead of another admin' do
    sign_in('admin')
    post users_path, params: { user: { name: 'Stock employee', email: 'stock-role@example.com',
      password: 'password123', role: 'inventory_employee' } }
    assert_redirected_to users_path
    assert_equal 'inventory_employee', User.find_by!(email: 'stock-role@example.com').role

    assert_no_difference('User.count') do
      post users_path, params: { user: { email: 'escalated@example.com', password: 'password123', role: 'super_admin' } }
    end
    assert_redirected_to users_path

    post users_path, params: { user: { email: 'default-role@example.com', password: 'password123' } }
    assert_equal 'cashier', User.find_by!(email: 'default-role@example.com').role

    employee = User.find_by!(email: 'stock-role@example.com')
    %w[super_admin unknown_role].each do |role|
      patch user_path(employee), params: { user: { role: role } }
      assert_redirected_to users_path
      assert_equal 'inventory_employee', employee.reload.role
    end
  end

  test 'deactivating an account invalidates its existing browser session' do
    sign_in('cashier')
    User.find_by!(email: 'cashier-boundary@example.com').update!(active: false)
    get inventory_index_path
    assert_redirected_to login_path
    assert_nil session[:user_id]
  end

  test 'inventory employee can count stock but cannot view financial reports or issue API credentials' do
    sign_in('inventory_employee')
    get new_inventory_count_path
    assert_response :success
    get reports_path
    assert_redirected_to root_path
    get api_access_tokens_path
    assert_redirected_to root_path
  end

  test 'reporting employee can report but cannot change counts or issue credentials' do
    sign_in('reporting')
    get sales_reports_path
    assert_response :success
    assert_no_difference('InventoryCount.count') do
      post inventory_counts_path, params: { inventory_count: { countedAt: Time.current }, items: [] }
    end
    assert_redirected_to inventory_counts_path
    get api_access_tokens_path
    assert_redirected_to root_path
  end

  private

  def sign_in(role)
    Current.tenant = tenants(:default_tenant)
    user = User.create!(tenant: Current.tenant, email: "#{role}-boundary@example.com", password: 'password123', role: role)
    post login_path, params: { email: user.email, password: 'password123' }
    assert_redirected_to root_path
  end
end
