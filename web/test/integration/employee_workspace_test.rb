# frozen_string_literal: true

require 'test_helper'

class EmployeeWorkspaceTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    @user = User.create!(tenant: @tenant, email: 'simple-worker@example.com', password: 'password123', role: 'employee')
    @worker = People::Employee.create!(first_name: 'Alex', last_name: 'Simple', user: @user)
    @other = People::Employee.create!(first_name: 'Someone', last_name: 'Private')
    @from = Date.new(2026, 10, 5)
    @to = @from + 6
    @sheet = @worker.timesheets.create!(period_start: @from, period_end: @to)
    @entry = @sheet.entries.create!(worked_on: @from, hours: 8, work_type: 'regular', notes: '=PRIVATEFORMULA()')
    @worker.pay_rates.create!(effective_on: @from, hourly_rate_cents: 2000, pay_type: 'hourly')
    @worker.leave_balances.create!(year: 2026, leave_type: 'vacation', accrued_hours: 48, used_hours: 8)
    @leave = @worker.leave_requests.create!(leave_type: 'vacation', starts_on: @from + 15, ends_on: @from + 15, hours: 8, reason: 'My vacation')
    @other.leave_requests.create!(leave_type: 'sick', starts_on: @from + 15, ends_on: @from + 15, hours: 8, reason: 'PRIVATE OTHER LEAVE')
  end
  teardown { Current.reset }

  def sign_in(user = @user)
    post login_path, params: { email: user.email, password: user == @user ? 'password123' : 'password' }
    Current.tenant = @tenant
  end

  test 'employee landing and shell focus on personal work without app promotion or business navigation' do
    sign_in
    assert_redirected_to employee_app_path
    get employee_app_path
    assert_response :success
    assert_equal 'no-store', response.headers['Cache-Control']
    assert_select 'h1', 'Hi, Alex'
    assert_select 'nav[aria-label="My workspace"]'
    assert_select 'a[href=?]', employee_reports_path
    assert_select 'a[href=?]', employee_time_off_path
    assert_select 'a[href="/sales"],a[href="/daily_reconciliations"],a[href="/reports"],nav[aria-label="Module areas"]', count: 0
    %w[Install\ Rupert Native\ employee\ app iPhone\ \&\ iPad].each { |text| refute_includes response.body, text }
    get employee_app_path(preview: 1, employee_id: @other.id)
    assert_select 'h1', 'Hi, Alex'
    refute_includes response.body, 'Staff preview'
    get time_clock_path
    assert_response :success
    assert_equal 'no-store', response.headers['Cache-Control']
    assert_select 'nav[aria-label="My workspace"]'
  end

  test 'week action forces current ownership and opens the same timesheet on retries' do
    sign_in
    Current.tenant = @tenant
    assert_difference 'People::Timesheet.count', 1 do
      2.times { post employee_week_path, params: { employee_id: @other.id } }
    end
    sheet = People::Timesheet.order(:id).last
    assert_equal @worker.id, sheet.employee_id
    assert_redirected_to people_timesheet_path(sheet)
  end

  test 'reports show only own hours and final pay snapshots with no payroll control' do
    Current.tenant = @tenant
    run = People::PayRun.create!(name: 'Final pay', period_start: @from, period_end: @to)
    run.finalize!
    @worker.payslips.create!(pay_run: run, hours: 8, gross_cents: 16000, net_cents: 14000, deductions_cents: 2000)
    @other.payslips.create!(pay_run: run, hours: 8, gross_cents: 99999, net_cents: 98765)
    draft = People::PayRun.create!(name: 'Draft pay', period_start: @from, period_end: @to)
    @worker.payslips.create!(pay_run: draft, hours: 8, gross_cents: 88888, net_cents: 87654)
    sign_in
    get employee_reports_path, params: { from: @from, to: @to, employee_id: @other.id }
    assert_response :success
    assert_equal 'no-store', response.headers['Cache-Control']
    assert_includes response.body, '$160.00'
    assert_includes response.body, '$140.00'
    refute_includes response.body, '$987.65'
    refute_includes response.body, '$876.54'
    assert_select 'a[href^="/people/pay_runs"]', count: 0
    get employee_reports_path(format: :csv), params: { from: @from, to: @to }
    assert_response :success
    assert_includes response.body, "'=PRIVATEFORMULA()"
    assert_includes response.body, '160.00'
    get employee_reports_path, params: { from: '2020-01-01', to: '2026-12-31' }
    assert_redirected_to employee_app_path
    get employee_reports_path, params: { from: 'invalid' }
    assert_redirected_to employee_app_path
    get reports_path
    assert_response :redirect
  end

  test 'personal time off forces ownership and review while calendar hides all other leave' do
    sign_in
    get employee_time_off_path, params: { month: '2026-10', employee_id: @other.id }
    assert_response :success
    assert_select '[role="table"][aria-label="Your calendar"]'
    assert_includes response.body, 'My vacation'
    assert_includes response.body, '40h remaining'
    refute_includes response.body, 'PRIVATE OTHER LEAVE'
    get employee_reports_path(format: :csv), params: { from: @from, to: @from + 30, kind: 'time_off', employee_id: @other.id }
    assert_response :success
    assert_includes response.body, 'My vacation'
    refute_includes response.body, 'PRIVATE OTHER LEAVE'
    get employee_time_off_path
    assert_select 'select[name="leave_request[employee_id]"]', count: 0
    assert_difference 'People::LeaveRequest.count', 1 do
      post employee_time_off_path, params: { leave_request: { employee_id: @other.id, status: 'approved', reviewed_by: @user.id, leave_type: 'personal', starts_on: '2026-11-01', ends_on: '2026-11-01', hours: 4, reason: 'Appointment' } }
    end
    leave = People::LeaveRequest.order(:id).last
    assert_equal @worker.id, leave.employee_id
    assert leave.requested?
    assert_nil leave.reviewed_by
    assert_no_difference 'People::LeaveBalance.count' do
      post cancel_employee_time_off_path(leave)
      post cancel_employee_time_off_path(leave)
    end
    assert leave.reload.cancelled?
    post cancel_employee_time_off_path(@other.leave_requests.first)
    assert_response :not_found
    post approve_people_leave_request_path(@leave)
    assert @leave.reload.requested?
    post employee_time_off_path, params: { leave_request: { leave_type: 'vacation', starts_on: '2026-11-02', ends_on: '2026-11-02' } }
    assert_response :unprocessable_entity
    assert_includes response.body, 'must be entered for paid time off'
    get employee_time_off_path, params: { month: 'not-a-month' }
    assert_redirected_to employee_app_path
  end

  test 'only authorized administrators configure rates and allowances while preserving used hours' do
    sign_in
    assert_no_difference ['People::PayRate.count', 'People::LeaveBalance.count'] do
      post add_pay_rate_people_employee_path(@worker), params: { pay_rate: { pay_type: 'hourly', amount: '20.50', pay_frequency: 'weekly', effective_on: '2026-10-01' } }
      post set_leave_allowance_people_employee_path(@worker), params: { leave_allowance: { leave_type: 'vacation', year: 2026, accrued_hours: 80, used_hours: 0 } }
    end
    sign_in(users(:regular_user))
    post add_pay_rate_people_employee_path(@worker), params: { pay_rate: { pay_type: 'hourly', amount: '20.50', pay_frequency: 'weekly', effective_on: '2026-10-01', employee_id: @other.id } }
    assert_redirected_to people_employee_path(@worker)
    assert_equal 2050, @worker.pay_rates.find_by!(effective_on: '2026-10-01').hourly_rate_cents
    post set_leave_allowance_people_employee_path(@worker), params: { leave_allowance: { leave_type: 'vacation', year: 2026, accrued_hours: 80, used_hours: 0, employee_id: @other.id } }
    balance = @worker.leave_balances.find_by!(year: 2026, leave_type: 'vacation')
    assert_equal 80, balance.accrued_hours
    assert_equal 8, balance.used_hours
    assert_no_difference 'People::PayRate.count' do
      post add_pay_rate_people_employee_path(@worker), params: { pay_rate: { pay_type: 'hourly', amount: '-10', effective_on: '2026-10-01' } }
    end
  end

  test 'employees on leave retain personal read access but cannot start a new shift' do
    @worker.place_on_leave!
    sign_in
    get employee_app_path
    assert_response :success
    assert_includes response.body, 'You’re on leave'
    get employee_time_off_path
    assert_response :success
    get employee_reports_path
    assert_response :success
    get people_timesheet_path(@sheet)
    assert_response :success
    assert_no_difference 'ClockShift.count' do
      post clock_in_time_clock_path, params: { request_token: 'on_leave_forbidden_token' }
    end
  end

  test 'missing employee link and unlinked owner preview never expose someone else records' do
    @worker.update!(user: nil)
    sign_in
    get employee_reports_path, params: { employee_id: @other.id }
    assert_redirected_to employee_app_path
    get employee_app_path
    assert_response :success
    refute_includes response.body, 'PRIVATE OTHER LEAVE'
    sign_in(users(:regular_user))
    assert_no_difference ['People::Employee.count', 'People::Timesheet.count', 'People::PayRate.count', 'ClockShift.count'] do
      get employee_app_path(preview: 1)
      assert_response :success
      assert_includes response.body, 'Example data'
      assert_select 'button[disabled]', text: 'Clock in'
      post employee_week_path, params: { preview: 1, employee_id: @other.id }
    end
  end
end
