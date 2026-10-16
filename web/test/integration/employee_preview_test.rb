# frozen_string_literal: true

require 'test_helper'

class EmployeePreviewTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    @admin = users(:regular_user)
    @worker = People::Employee.create!(first_name: 'PRIVATE', last_name: 'REAL WORKER')
    @sheet = @worker.timesheets.create!(period_start: Date.current.beginning_of_week, period_end: Date.current.end_of_week)
    @sheet.entries.create!(worked_on: Date.current, hours: 7, notes: 'PRIVATE REAL HOURS')
    @leave = @worker.leave_requests.create!(leave_type: 'personal', starts_on: Date.current, ends_on: Date.current, hours: 4, reason: 'PRIVATE REAL LEAVE')
    @worker.pay_rates.create!(effective_on: Date.current, pay_type: 'hourly', hourly_rate_cents: 9876)
    post login_path, params: { email: @admin.email, password: 'password' }
    Current.tenant = @tenant
  end
  teardown { Current.reset }

  def preview_paths
    [employee_app_path(preview: 1), employee_preview_timesheets_path, employee_preview_timesheet_path('current'),
      employee_preview_timesheet_path('previous'), employee_preview_pay_path, employee_preview_time_off_path,
      employee_preview_reports_path, employee_preview_time_clock_path, employee_privacy_path(preview: 1)]
  end

  def employee_rows
    [People::Employee, People::Timesheet, People::TimesheetEntry, People::TimesheetEvent, People::PayRate,
      People::PayRun, People::Payslip, People::LeaveRequest, People::LeaveBalance, ClockShift, ClockCorrection,
      EmployeeWorkReport, EmployeeSourceIdentity, EmployeeAccessGrant, EmployeeAppSession, User].map do |model|
      [model.name, model.unscoped.order(:id).map(&:attributes)]
    end.to_h
  end

  test 'all preview screens use only synthetic records for linked and unlinked administrators' do
    [nil, @admin].each do |user|
      @worker.update!(user: user)
      before = employee_rows
      queries = []
      subscriber = lambda do |*, event|
        next if event[:name] == 'SCHEMA'
        queries << event[:sql] if event[:sql].match?(/\b(?:employees|timesheets|timesheet_entries|pay_rates|pay_runs|payslips|leave_requests|leave_balances|clock_shifts|employee_work_reports)\b/i)
      end
      TimeClockService.expects(:worker_for).never
      ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record') do
        preview_paths.each do |path|
          get path, params: { employee_id: @worker.id, user_id: @admin.id }
          assert_response :success
          assert_equal 'no-store', response.headers['Cache-Control']
          assert_includes response.body, 'Example data only'
          refute_includes response.body, 'PRIVATE REAL'
          refute_includes response.body, 'PRIVATE REAL WORKER'
          assert_select 'a[href^="/people"], a[href="/sales"], a[href="/reconcile"], a[href="/time_clock"]', count: 0
          assert_select 'nav[aria-label="My workspace"] a', count: 5
          response.parsed_body.css('form:not([method="get"])').each do |form|
            assert form['action'].start_with?('/employee/preview/')
            assert_equal 1, form.css('fieldset[disabled]').size
          end
        end
      end
      assert_empty queries, 'Preview must not query real employee or payroll tables'
      assert_equal before, employee_rows
    end
  end

  test 'calendar navigation filters and downloads stay in preview and contain example data only' do
    get employee_preview_time_off_path
    assert_select 'a[aria-label="Next month"][href^="/employee/preview/time-off"]'
    assert_select 'a[aria-label="Previous month"][href^="/employee/preview/time-off"]'
    assert_includes response.body, '64h remaining'
    assert_includes response.body, 'Example vacation request'
    get employee_preview_time_off_path(month: Date.current.next_month.strftime('%Y-%m'))
    assert_response :success
    assert_select 'h2', Date.current.next_month.strftime('%B %Y')
    from = Date.current.beginning_of_week - 7
    to = Date.current.beginning_of_week + 13
    get employee_preview_reports_path, params: { from: from, to: to }
    assert_select 'form[method="get"][action="/employee/preview/reports"]'
    assert_select 'a[href^="/employee/preview/reports.csv"]', count: 2
    assert_includes response.body, 'Example response:'
    assert_includes response.body, '$680.00'
    %w[hours time_off].each do |kind|
      get employee_preview_reports_path(format: :csv), params: { from: from, to: to, kind: kind, employee_id: @worker.id }
      assert_response :success
      assert_includes response.headers['Content-Disposition'], 'example-'
      assert_includes response.body, kind == 'hours' ? 'Example workday' : 'Example vacation request'
      refute_includes response.body, 'PRIVATE REAL'
    end
    get employee_preview_reports_path, params: { from: 'invalid' }
    assert_redirected_to employee_app_path(preview: 1)
    get employee_preview_reports_path, params: { from: '2020-01-01', to: '2026-12-31' }
    assert_redirected_to employee_app_path(preview: 1)
    get employee_preview_time_off_path, params: { month: '2026-99' }
    assert_redirected_to employee_app_path(preview: 1)
    get employee_preview_timesheet_path(@sheet.id)
    assert_response :not_found
  end

  test 'forged preview mutations cannot change a linked administrators real records' do
    @worker.update!(user: @admin)
    before = employee_rows
    requests = [[:post, employee_week_path], [:post, clock_in_time_clock_path], [:post, clock_out_time_clock_path],
      [:post, request_correction_time_clock_path(1)], [:post, employee_time_off_path], [:post, cancel_employee_time_off_path(@leave)],
      [:post, employee_problem_path], [:post, add_entry_people_timesheet_path(@sheet)], [:post, submit_people_timesheet_path(@sheet)],
      [:patch, people_timesheet_path(@sheet)], [:delete, people_timesheet_path(@sheet)], [:post, employee_access_path(@worker)],
      [:patch, employee_setup_path], [:post, revoke_employee_device_path(1)]]
    assert_no_enqueued_jobs do
      requests.each do |method, path|
        public_send(method, path, params: { preview: 1, employee_id: @worker.id, leave_request: { leave_type: 'personal', starts_on: Date.current, ends_on: Date.current, hours: 4 } })
        assert_response :forbidden
      end
      post clock_in_time_clock_path, params: { preview: 1, request_token: 'forged-json-preview' }, as: :json
      assert_response :forbidden
      [employee_preview_time_off_path, employee_preview_reports_path, employee_preview_timesheet_path('current')].each do |path|
        post path
        assert_response :not_found
      end
    end
    assert_equal before, employee_rows
  end

  test 'preview is unavailable to ordinary employees and does not grant business permissions' do
    user = User.create!(tenant: @tenant, email: 'preview-worker@example.invalid', password: 'password123', role: 'employee')
    @worker.update!(user: user)
    post login_path, params: { email: user.email, password: 'password123' }
    preview_paths.reject { |path| path.include?('?') }.each do |path|
      get path
      assert_response :forbidden
    end
    get employee_app_path(preview: 1)
    assert_response :success
    refute_includes response.body, 'Example data only'
    assert_includes response.body, 'Hi, PRIVATE'
    get sales_path
    assert_response :redirect
  end
end
