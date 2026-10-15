# frozen_string_literal: true

require 'test_helper'

class SizeMemberAccessTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    @family = SizeFamily.create!(name: 'Protected size definitions', mode: 'approval')
    @member = @family.members.create!(sku: 'protected-3-5', grams: '3.5')
    SquareClient.expects(:request).never
    SizeDeriver.expects(:process).never
    SizeDeriver.expects(:process_all!).never
  end

  teardown do
    Current.reset
  end

  %w[reader cashier inventory_employee reporting manager].each do |role|
    test "#{role} cannot add or remove size definitions through direct URLs" do
      sign_in(role: role)
      assert_member_changes_denied
    end
  end

  test 'a settings read delegate can view sizes but cannot change definitions' do
    sign_in(role: 'reader', permissions: ['settings.read'])
    get size_families_path
    assert_response :success
    assert_includes response.body, @family.name

    assert_member_changes_denied
  end

  test 'an administrator can add and remove a local size definition without provider calls' do
    sign_in(role: 'admin')
    assert_local_member_changes_allowed
  end

  test 'explicit settings write delegation permits local size definitions' do
    sign_in(role: 'reader', permissions: ['settings.write'])
    assert_local_member_changes_allowed
  end

  test 'a settings writer cannot mutate another workspace size definitions' do
    foreign_tenant = Tenant.create!(name: 'Other size shop', subdomain: "foreign-size-#{SecureRandom.hex(4)}")
    foreign_family = SizeFamily.create!(tenant_id: foreign_tenant.id, name: 'Foreign sizes', mode: 'approval')
    foreign_member = foreign_family.members.create!(tenant_id: foreign_tenant.id, sku: 'foreign-size', grams: '7')
    sign_in(role: 'admin')

    assert_no_difference('SizeFamilyMember.unscoped.count') do
      post add_member_size_family_path(foreign_family), params: { sku: 'unauthorized', grams: '14' }
    end
    assert_response :not_found

    assert_no_difference('SizeFamilyMember.unscoped.count') do
      post remove_member_size_family_path(foreign_family), params: { member_id: foreign_member.id }
    end
    assert_response :not_found
    assert_equal '7.0', foreign_member.reload.grams.to_s
  end

  private

  def sign_in(role:, permissions: nil)
    Current.tenant = @tenant
    user = User.create!(tenant: @tenant, email: "size-access-#{SecureRandom.hex(6)}@example.com",
      password: 'password123', role: role)
    user.update_permission_overrides!(permissions) if permissions
    post login_path, params: { email: user.email, password: 'password123' }
    assert_redirected_to root_path
    assert_equal user.id, session[:user_id]
  end

  def assert_member_changes_denied
    before = size_definitions
    post add_member_size_family_path(@family), params: { sku: 'unauthorized', grams: '1000' }
    assert_redirected_to root_path
    assert_equal before, size_definitions

    post remove_member_size_family_path(@family), params: { member_id: @member.id }
    assert_redirected_to root_path
    assert_equal before, size_definitions
  end

  def size_definitions
    [SizeFamily.unscoped.where(tenant_id: @tenant.id).order(:id).map(&:attributes),
      SizeFamilyMember.unscoped.where(tenant_id: @tenant.id).order(:id).map(&:attributes)]
  end

  def assert_local_member_changes_allowed
    assert_difference('SizeFamilyMember.unscoped.count', 1) do
      post add_member_size_family_path(@family), params: { sku: 'authorized-7', grams: '7' }
    end
    assert_redirected_to edit_size_family_path(@family)
    added = SizeFamilyMember.unscoped.find_by!(family_id: @family.id, sku: 'authorized-7')
    assert_equal @tenant.id, added.tenant_id
    assert_equal '7.0', added.grams.to_s

    assert_difference('SizeFamilyMember.unscoped.count', -1) do
      post remove_member_size_family_path(@family), params: { member_id: added.id }
    end
    assert_redirected_to edit_size_family_path(@family)
    assert SizeFamilyMember.unscoped.exists?(@member.id)
  end
end
