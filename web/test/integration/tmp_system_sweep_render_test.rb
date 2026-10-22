# frozen_string_literal: true

require 'test_helper'

# Temporary render check for the System sweep; deleted after the run.
class TmpSystemSweepRenderTest < ActionDispatch::IntegrationTest
  teardown { Current.reset }

  test 'setup page renders the form template when no tenant exists' do
    Tenant.stubs(:exists?).returns(false)
    get setup_path
    assert_response :success
    assert_select 'header.page-header h1.page-title', text: 'Set up your workspace'
    assert_select 'h1', count: 1
    assert_select '.page-narrow form fieldset legend', count: 2
    assert_select '.form-actions input[type=submit][value="Create workspace"]'
  end

  test 'tenants list and add tenant pages render for a super admin' do
    user = users(:regular_user)
    user.update!(role: 'super_admin')
    post login_path, params: { email: user.email, password: 'password' }
    get tenants_path
    assert_response :success
    assert_select 'header.page-header h1.page-title', text: 'Tenants'
    assert_select 'a.btn-primary', text: 'Add tenant'
    assert_select '.table-region table.table'
    get new_tenant_path
    assert_response :success
    assert_select 'header.page-header h1.page-title', text: 'Add tenant'
    assert_select '.form-actions input[type=submit][value="Save"]'
    assert_select '.form-actions a.btn-ghost', text: 'Cancel'
  end

  test 'sign in page keeps one h1 and token labels' do
    get login_path
    assert_response :success
    assert_select 'h1', count: 1
    assert_select 'label.field-label', minimum: 2
    assert_select '[class*="text-["]', count: 0
  end
end
