# frozen_string_literal: true

require 'test_helper'

class EmployeeAccessReviewTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    @admin = users(:regular_user)
    @user = User.create!(tenant: @tenant, email: 'access-badge-worker@example.invalid', password: 'password123', role: 'employee')
    @worker = People::Employee.create!(first_name: 'Review', last_name: 'Worker', user: @user)
    @held = People::Employee.create!(first_name: 'Held', last_name: 'Worker')
  end
  teardown { Current.reset }

  def sign_in(user = @admin)
    post login_path, params: { email: user.email, password: user == @admin ? 'password' : 'password123' }
  end

  test 'directory and review display actual employee tabs without exposing financial grants or changing accounts' do
    sign_in
    before = [@user.attributes, @worker.attributes, EmployeeAccessGrant.count]
    get people_employees_path
    assert_response :success
    assert_select '[aria-label="Access for Review Worker"]' do
      assert_select 'span', text: 'POS · Checkout'
      assert_select 'span', text: 'Timesheets · Own · submit'
      assert_select 'span', text: /Sales|Reconciliation|Payroll/, count: 0
    end
    get people_employee_path(@worker)
    assert_response :success
    assert_select '#access select[name="user[role]"] option[selected]', text: 'Employee'
    assert_select '#access input[type="submit"][value="Save access level"]'
    assert_select '#access a[href=?]', edit_user_path(@user)
    assert_equal before, [@user.reload.attributes, @worker.reload.attributes, EmployeeAccessGrant.count]
    get people_employee_path(@held)
    assert_select '#access', text: /No login/
    assert_select '#access select[name="user[role]"]', count: 0
  end

  test 'effective overrides control badges and disabled accounts show no accessible tabs' do
    @user.update!(role: 'manager')
    @user.update_permission_overrides!(%w[hr.read inventory.read])
    sign_in
    get people_employee_path(@worker)
    assert_select '#access span', text: 'Stock comparison · View'
    assert_select '#access span', text: /Sales ·|Reports ·|Financial close ·/, count: 0
    @user.update!(active: false)
    get people_employee_path(@worker)
    assert_select '#access', text: /Login disabled/
    assert_select '#access .pill-fern', count: 0
  end

  test 'admin can save a permission level and return to this employee without creating grants or changing HR' do
    sign_in
    before = @worker.attributes
    assert_no_difference 'EmployeeAccessGrant.count' do
      patch user_path(@user), params: { return_employee_id: @worker.id, user: { role: 'employee', active: 'false' } }
    end
    assert_redirected_to people_employee_path(@worker, anchor: 'access')
    refute @user.reload.active?
    assert_equal before, @worker.reload.attributes
    patch user_path(@user), params: { return_employee_id: @worker.id, user: { role: 'reader', active: 'true' } }
    assert_equal 'reader', @user.reload.role
    follow_redirect!
    assert_select '#access span', text: 'Sales · View'
  end

  test 'ordinary employees and HR-only managers cannot edit permission levels even by forged requests' do
    sign_in(@user)
    patch user_path(@admin), params: { user: { role: 'employee' } }
    assert_response :redirect
    assert_equal 'admin', @admin.reload.role
    delete logout_path
    @user.update!(role: 'manager')
    @user.update_permission_overrides!(%w[hr.read hr.write users.read users.write])
    sign_in(@user)
    get people_employee_path(@worker)
    assert_response :success
    assert_select '#access select[name="user[role]"]', count: 0
    patch user_path(@user), params: { user: { role: 'admin' } }
    assert_equal 'manager', @user.reload.role
  end

  test 'freshness uses successful tenant receipts without employee source payloads' do
    Current.user = @admin
    SquareClient.stubs(:configured?).returns(true)
    SquareTimecardSync.configure!(enabled: true)
    SyncAttempt.create!(source: 'square', operation: 'timecards', status: 'succeeded', queued_at: 5.minutes.ago, finished_at: 4.minutes.ago)
    SyncAttempt.create!(source: 'square', operation: 'timecards', status: 'failed', queued_at: 1.minute.ago, finished_at: Time.current, error_category: 'unknown')
    sign_in(@user)
    get employee_app_path
    assert_response :success
    assert_includes response.body, 'Square hours update every 15 minutes'
    assert_includes response.body, 'Last synced'
    assert_includes response.body, 'previous hours are retained'
    refute_includes response.body, @admin.email
  end
end
