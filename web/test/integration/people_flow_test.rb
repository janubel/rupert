# frozen_string_literal: true

require 'test_helper'

# End-to-end coverage of the People / HR module set: employees, departments,
# positions, timesheets, leave & PTO, and payroll.
class PeopleFlowTest < ActionDispatch::IntegrationTest
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
    @admin = User.create!(email: 'hr@example.com', password: 'password123', role: 'admin', tenant_id: @tenant.id,
      name: 'HR Boss')
    post login_path, params: { email: 'hr@example.com', password: 'password123' }
    Current.tenant = @tenant
  end

  teardown do
    Current.tenant = nil
  end

  def get_page(path)
    get(path, params: { shop: 'm11u0i-sb.myshopify.com', embedded: '1', host: 'test-host' })
  end

  def post_page(path, params: {})
    post(path, params: params.merge(shop: 'm11u0i-sb.myshopify.com', embedded: '1', host: 'test-host'))
  end

  test 'employees index shows the directory and stats' do
    dept = People::Department.create!(tenant_id: @tenant.id, name: 'Retail')
    People::Employee.create!(tenant_id: @tenant.id, first_name: 'Alex', last_name: 'Morgan', employee_number: 'E1',
      hire_date: Date.today, department_id: dept.id)

    get_page people_employees_path
    assert_response :success
    assert_select 'h1', /Employees/
    assert_select 'td', /Alex Morgan/
    assert_select 'td', /Retail/
  end

  test 'create an employee linked to a department and position' do
    dept = People::Department.create!(tenant_id: @tenant.id, name: 'Retail', code: 'RET')
    position = People::Position.create!(tenant_id: @tenant.id, name: 'Cashier', department_id: dept.id)

    get_page new_people_employee_path
    assert_response :success

    post_page people_employees_path, params: {
      employee: { first_name: 'Jamie', last_name: 'Rivera', employee_number: 'E2026-001', department_id: dept.id, position_id: position.id, hire_date: '2026-01-05', employment_type: 'full_time' }
    }
    follow_redirect!
    assert_response :success

    employee = People::Employee.find_by!(employee_number: 'E2026-001')
    assert_equal dept.id, employee.department_id
    assert_equal position.id, employee.position_id
    assert employee.active?
    assert_select 'h1', /Jamie Rivera/
  end

  test 'employee lifecycle transitions through the AASM states' do
    employee = People::Employee.create!(tenant_id: @tenant.id, first_name: 'Sam', last_name: 'Lee',
      employee_number: 'E2')

    post_page transition_people_employee_path(employee, event: 'place_on_leave')
    follow_redirect!
    assert_response :success
    assert employee.reload.on_leave?

    post_page transition_people_employee_path(employee, event: 'return_to_work')
    follow_redirect!
    assert employee.reload.active?

    post_page transition_people_employee_path(employee, event: 'terminate')
    follow_redirect!
    employee.reload
    assert employee.terminated?
    assert_equal Date.today, employee.termination_date
  end

  test 'departments and positions can be created' do
    get_page new_people_department_path
    assert_response :success
    post_page people_departments_path, params: { department: { name: 'Kitchen', code: 'KIT' } }
    follow_redirect!
    assert_response :success
    assert People::Department.exists?(name: 'Kitchen')

    get_page new_people_position_path
    assert_response :success
    post_page people_positions_path, params: { position: { name: 'Line cook', pay_grade: 'G2' } }
    follow_redirect!
    assert_response :success
    assert People::Position.exists?(name: 'Line cook')
  end

  test 'timesheet lifecycle: draft, entries, submit, approve, reject, reopen' do
    employee = People::Employee.create!(tenant_id: @tenant.id, first_name: 'Pat', last_name: 'Kim',
      employee_number: 'E3')

    post_page people_timesheets_path, params: {
      timesheet: { employee_id: employee.id, period_start: '2026-07-27', period_end: '2026-08-02' }
    }
    follow_redirect!
    assert_response :success

    timesheet = People::Timesheet.find_by!(period_start: Date.new(2026, 7, 27))
    assert_equal 'draft', timesheet.status

    post_page add_entry_people_timesheet_path(timesheet), params: {
      timesheet_entry: { worked_on: '2026-07-27', hours: '8', work_type: 'regular' }
    }
    follow_redirect!
    assert_response :success
    timesheet.reload
    assert_equal 8.0, timesheet.total_hours

    post_page submit_people_timesheet_path(timesheet)
    follow_redirect!
    assert timesheet.reload.submitted?

    post_page approve_people_timesheet_path(timesheet)
    follow_redirect!
    timesheet.reload
    assert timesheet.approved?
    assert_equal @admin.id, timesheet.reviewed_by

    # A second timesheet that gets rejected and reopened
    other = People::Timesheet.create!(tenant_id: @tenant.id, employee_id: employee.id, period_start: '2026-08-03',
      period_end: '2026-08-09')
    other.entries.create!(tenant_id: @tenant.id, worked_on: '2026-08-03', hours: 8, work_type: 'regular')
    other.submit!
    post_page reject_people_timesheet_path(other)
    follow_redirect!
    assert other.reload.rejected?
    post_page reopen_people_timesheet_path(other)
    follow_redirect!
    assert other.reload.draft?
  end

  test 'leave request: create, approve consumes balance, cancel gives it back' do
    employee = People::Employee.create!(tenant_id: @tenant.id, first_name: 'Riley', last_name: 'Chen',
      employee_number: 'E4')

    post_page people_leave_requests_path, params: {
      leave_request: { employee_id: employee.id, leave_type: 'vacation', starts_on: '2026-09-01', ends_on: '2026-09-05' }
    }
    follow_redirect!
    assert_response :success
    request = People::LeaveRequest.find_by!(employee_id: employee.id)
    assert request.requested?

    post_page approve_people_leave_request_path(request)
    follow_redirect!
    assert request.reload.approved?
    balance = employee.leave_balance('vacation', 2026)
    assert_equal 40.0, balance.used_hours # 5 days × 8h

    post_page cancel_people_leave_request_path(request)
    follow_redirect!
    assert request.reload.cancelled?
    assert_equal 0.0, employee.leave_balance('vacation', 2026).used_hours
  end

  test 'payroll: pay run generates payslips from approved timesheets, finalizes and pays' do
    employee = People::Employee.create!(tenant_id: @tenant.id, first_name: 'Morgan', last_name: 'Zhao',
      employee_number: 'E5')
    rate = People::PayRate.create!(tenant_id: @tenant.id, employee_id: employee.id, pay_type: 'hourly',
      hourly_rate_cents: 2000, effective_on: '2026-07-01')

    timesheet = People::Timesheet.create!(tenant_id: @tenant.id, employee_id: employee.id, period_start: '2026-07-27',
      period_end: '2026-08-02')
    [27, 28, 29, 30, 31].each do |day|
      timesheet.entries.create!(tenant_id: @tenant.id, worked_on: Date.new(2026, 7, day), hours: 8,
        work_type: 'regular')
    end
    timesheet.entries.create!(tenant_id: @tenant.id, worked_on: '2026-07-28', hours: 2, work_type: 'overtime')
    timesheet.submit!
    timesheet.approve!

    get_page new_people_pay_run_path
    assert_response :success
    post_page people_pay_runs_path, params: {
      pay_run: { name: 'Pay July', period_start: '2026-07-27', period_end: '2026-08-02' }
    }
    follow_redirect!
    assert_response :success

    pay_run = People::PayRun.find_by!(name: 'Pay July')
    assert_equal 1, pay_run.payslips.count
    slip = pay_run.payslips.first
    assert_equal 42.0, slip.hours
    assert_equal rate.id, slip.pay_rate_id
    # 40h × $20 + 2h × $30 (1.5x)
    assert_equal 86_000, slip.gross_cents
    assert_equal 12_900, slip.deductions_cents # 15% default
    assert_equal 73_100, slip.net_cents

    post_page finalize_people_pay_run_path(pay_run)
    follow_redirect!
    pay_run.reload
    assert pay_run.finalized?
    assert_equal 86_000, pay_run.total_gross_cents
    assert_equal 73_100, pay_run.total_net_cents

    post_page pay_people_pay_run_path(pay_run)
    follow_redirect!
    pay_run.reload
    assert pay_run.paid?
    assert_equal Date.today, pay_run.paid_on
  end

  test 'a cashier cannot reach HR or payroll pages' do
    User.create!(email: 'cashier@example.com', password: 'password123', role: 'cashier', tenant_id: @tenant.id,
      name: 'Cashier')
    delete logout_path
    post login_path, params: { email: 'cashier@example.com', password: 'password123' }

    get_page people_employees_path
    follow_redirect!
    assert_match(/don't have permission/, flash[:alert])

    get_page people_pay_runs_path
    follow_redirect!
    assert_match(/don't have permission/, flash[:alert])
  end

  test 'dashboard people widget shows HR stats for users with hr.read' do
    EnvStore.set('SHOPIFY_CLIENT_ID', 'client-id')
    EnvStore.set('SHOPIFY_CLIENT_SECRET', 'client-secret')
    People::Employee.create!(tenant_id: @tenant.id, first_name: 'Dash', last_name: 'Board', employee_number: 'E-W1')
    on_leave = People::Employee.create!(tenant_id: @tenant.id, first_name: 'Away', last_name: 'Today',
      employee_number: 'E-W2')
    on_leave.place_on_leave!

    get_page root_path
    assert_response :success
    assert_select 'h2', /People/
    assert_match(/On leave/, response.body)
    assert_match(/Timesheets awaiting review/, response.body)
  end

  test 'dashboard people widget defers to hr permission for its content' do
    EnvStore.set('SHOPIFY_CLIENT_ID', 'client-id')
    EnvStore.set('SHOPIFY_CLIENT_SECRET', 'client-secret')
    User.create!(email: 'cashier2@example.com', password: 'password123', role: 'cashier', tenant_id: @tenant.id,
      name: 'Cashier')
    delete logout_path
    post login_path, params: { email: 'cashier2@example.com', password: 'password123' }

    get_page root_path
    assert_response :success
    assert_select '[data-widget-key=people]', count: 0
  end
end
