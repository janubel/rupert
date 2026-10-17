# frozen_string_literal: true

require 'test_helper'

class UserCreationRoleTest < ActionDispatch::IntegrationTest
  setup do
    @subdomain = "urole#{SecureRandom.hex(4)}"
    @tenant = Tenant.create!(name: 'Role Co', subdomain: @subdomain)
    @admin = User.create!(email: 'role-admin@example.com', password: 'password123', role: 'admin', name: 'Admin',
      tenant_id: @tenant.id)
    @super = User.create!(email: 'role-super@example.com', password: 'password123', role: 'super_admin',
      name: 'Super', tenant_id: @tenant.id)
    Current.tenant = @tenant
    host!("#{@subdomain}.example.com")
  end

  teardown do
    Current.tenant = nil
  end

  def sign_in(user)
    post login_path, params: { email: user.email, password: 'password123' }
  end

  test 'accounts created without a role start as employee, not admin' do
    sign_in(@admin)
    post users_path, params: { user: { name: 'New', email: 'new1@example.com', password: 'password123' } }

    assert_equal 'employee', User.find_by!(email: 'new1@example.com').role
  end

  test 'admin cannot create a super admin' do
    sign_in(@admin)
    post users_path,
      params: { user: { name: 'Sneaky', email: 'new2@example.com', password: 'password123', role: 'super_admin' } }

    assert_nil User.find_by(email: 'new2@example.com')
  end

  test 'super admin can choose the role' do
    sign_in(@super)
    post users_path,
      params: { user: { name: 'Boss', email: 'new3@example.com', password: 'password123', role: 'manager' } }

    assert_equal 'manager', User.find_by!(email: 'new3@example.com').role
  end
end
