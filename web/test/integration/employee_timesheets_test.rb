# frozen_string_literal: true

require 'test_helper'

class EmployeeTimesheetsTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = Tenant.create!(name: 'Employee Test', subdomain: 'employee-test')
    @user = User.create!(tenant: @tenant, email: 'worker-ts@example.com', password: 'password123', role: 'employee')
    @manager = User.create!(tenant: @tenant, email: 'manager-ts@example.com', password: 'password123', role: 'manager')
    @admin = User.create!(tenant: @tenant, email: 'admin-ts@example.com', password: 'password123', role: 'admin')
    Current.tenant = @tenant
    @employee = People::Employee.create!(first_name: 'Alex', last_name: 'Worker', user: @user, employee_number: 'TS-1', email: @user.email)
    @other = People::Employee.create!(first_name: 'Other', last_name: 'Worker', employee_number: 'TS-2')
    @sheet = People::Timesheet.create!(employee: @employee, period_start: '2026-07-27', period_end: '2026-08-02')
    @other_sheet = People::Timesheet.create!(employee: @other, period_start: '2026-07-27', period_end: '2026-08-02')
  end
  teardown { Current.reset }

  def sign_in(user = @user)
    post login_path, params: { email: user.email, password: 'password123' }
    Current.tenant = @tenant
  end

  def add_entry(sheet = @sheet, hours: 8, day: '2026-07-27')
    sheet.entries.create!(worked_on: day, hours: hours, work_type: 'regular')
  end

  def app_login(user = @user)
    post '/api/v1/employee/session', params: { email: user.email, password: 'password123', device_name: 'Test phone' }, as: :json
    assert_response :created
    { 'Authorization' => "Bearer #{response.parsed_body.fetch('token')}" }
  end

  test 'employee browser shows only own timesheets and forces ownership on create' do
    sign_in
    get people_timesheets_path
    assert_response :success
    assert_select 'td', /Alex Worker/
    assert_select 'td', text: /Other Worker/, count: 0
    get people_timesheet_path(@other_sheet)
    assert_response :not_found
    post people_timesheets_path, params: { timesheet: { employee_id: @other.id, period_start: '2026-08-03', period_end: '2026-08-09' } }
    assert_response :redirect
    created = People::Timesheet.unscoped.order(:id).last
    assert_equal @employee.id, created.employee_id
  end

  test 'employee can edit entries submit and reopen rejected but cannot review' do
    sign_in
    post add_entry_people_timesheet_path(@sheet), params: { timesheet_entry: { worked_on: '2026-07-27', hours: 8, work_type: 'regular', notes: 'Stock work' } }
    entry = @sheet.entries.first
    patch update_entry_people_timesheet_path(@sheet, entry_id: entry.id), params: { timesheet_entry: { worked_on: '2026-07-27', hours: 7, work_type: 'regular' } }
    assert_equal 7, entry.reload.hours
    post submit_people_timesheet_path(@sheet)
    assert @sheet.reload.submitted?
    assert @sheet.submitted_at
    post approve_people_timesheet_path(@sheet)
    assert @sheet.reload.submitted?
    assert_nil @sheet.reviewed_by
    sign_in(@manager)
    post reject_people_timesheet_path(@sheet), params: { review_note: 'Please check Tuesday.' }
    assert @sheet.reload.rejected?
    assert_equal 'Please check Tuesday.', @sheet.review_note
    sign_in
    post reopen_people_timesheet_path(@sheet)
    assert @sheet.reload.draft?
    assert_nil @sheet.reviewed_by
    assert_nil @sheet.review_note
    assert_equal %w[add_entry update_entry submit reject reopen], @sheet.events.order(:id).pluck(:action)
  end

  test 'submitted and approved timesheets cannot be edited through direct PATCH' do
    add_entry
    @sheet.submit!
    sign_in
    patch people_timesheet_path(@sheet), params: { timesheet: { notes: 'Tampering', period_end: '2026-08-04' } }
    assert_nil @sheet.reload.notes
    assert_equal Date.new(2026, 8, 2), @sheet.period_end
    assert_no_difference 'People::TimesheetEntry.unscoped.count' do
      post add_entry_people_timesheet_path(@sheet), params: { timesheet_entry: { worked_on: '2026-07-27', hours: 8, work_type: 'regular' } }
    end
    sign_in(@manager)
    post approve_people_timesheet_path(@sheet)
    assert @sheet.reload.approved?
    first_review = @sheet.reviewed_at
    post reject_people_timesheet_path(@sheet)
    assert @sheet.reload.approved?
    assert_equal first_review, @sheet.reviewed_at
  end

  test 'reviewers cannot approve their own linked employee record' do
    @employee.update!(user: @manager)
    add_entry
    @sheet.submit!
    sign_in(@manager)
    post approve_people_timesheet_path(@sheet)
    assert @sheet.reload.submitted?
    assert_nil @sheet.reviewed_by
  end

  test 'validation rejects cross workspace records overlap invalid dates and daily totals' do
    foreign = Tenant.create!(name: 'Foreign', subdomain: 'foreign-ts')
    worker = People::Employee.unscoped.create!(tenant: foreign, first_name: 'Foreign', last_name: 'Worker', employee_number: 'F1')
    bad = People::Timesheet.new(employee: worker, period_start: '2026-08-10', period_end: '2026-08-16')
    assert_not bad.valid?
    overlap = People::Timesheet.new(employee: @employee, period_start: '2026-07-30', period_end: '2026-08-05')
    assert_not overlap.valid?
    add_entry(hours: 20)
    assert_not @sheet.entries.new(worked_on: '2026-07-27', hours: 5, work_type: 'overtime').valid?
    assert_not @sheet.entries.new(worked_on: '2026-08-03', hours: 1, work_type: 'regular').valid?
    assert_not @sheet.entries.new(worked_on: '2026-07-28', hours: -1, work_type: 'regular').valid?
    assert_not @sheet.entries.new(worked_on: '2026-07-28', hours: 1, work_type: 'unknown').valid?
  end

  test 'approved payroll snapshots block reopening' do
    add_entry
    @sheet.submit!
    @sheet.approve!
    run = People::PayRun.create!(name: 'Locked payroll', period_start: @sheet.period_start, period_end: @sheet.period_end)
    People::Payslip.create!(pay_run: run, employee: @employee, hours: 8, gross_cents: 100, deductions_cents: 0, net_cents: 100)
    sign_in(@manager)
    post reopen_people_timesheet_path(@sheet)
    assert @sheet.reload.approved?
    assert_match(/included in payroll/, flash[:alert])
  end

  test 'clock import splits midnight is repeatable and blocks pending corrections' do
    Current.user = @user
    shift = ClockShift.create!(employee: @employee, user: @user, employee_key: @employee.id.to_s, employee_name: @employee.name,
      employment_type: 'full_time', started_at: Time.zone.parse('2026-07-27 23:00'), ended_at: Time.zone.parse('2026-07-28 02:00'), request_token: 'clock_import_token_123')
    workflow = TimesheetWorkflow.new
    2.times { workflow.change(@sheet, :import_shifts) }
    assert_equal 2, @sheet.entries.count
    assert_equal 3, @sheet.total_hours
    assert_equal [1, 2], @sheet.entries.ordered.pluck(:hours)
    TimeClockService.request_correction(user: @user, shift_id: shift.id, attributes: { proposed_started_at: shift.started_at, proposed_ended_at: shift.ended_at + 1.hour, reason: 'Forgot to clock out' })
    assert_raises(TimesheetWorkflow::Error) { workflow.change(@sheet, :import_shifts) }
  end

  test 'mobile login token is hashed limited to self and revoked at logout' do
    headers = app_login
    secret = headers['Authorization'].split.last
    record = EmployeeAppSession.unscoped.last
    assert_not_equal secret, record.token_digest
    get '/api/v1/employee/timesheets', headers: headers
    assert_response :success
    assert_equal [@sheet.id], response.parsed_body['data'].map { |s| s['id'] }
    get "/api/v1/employee/timesheets/#{@other_sheet.id}", headers: headers
    assert_response :not_found
    get '/api/v1/inventory', headers: headers
    assert_response :unauthorized
    delete '/api/v1/employee/session', headers: headers
    assert_response :no_content
    get '/api/v1/employee/session', headers: headers
    assert_response :unauthorized
  end

  test 'mobile mutation rejects review actions and cross employee entry removal' do
    add_entry(@other_sheet)
    headers = app_login
    post "/api/v1/employee/timesheets/#{@sheet.id}/entries", params: { timesheet_entry: { worked_on: '2026-07-27', hours: 8, work_type: 'regular' } }, headers: headers, as: :json
    assert_response :success
    delete "/api/v1/employee/timesheets/#{@sheet.id}/entries/#{@other_sheet.entries.first.id}", headers: headers
    assert_response :not_found
    post "/api/v1/employee/timesheets/#{@sheet.id}/actions/submit", headers: headers, as: :json
    assert_response :success
    post "/api/v1/employee/timesheets/#{@sheet.id}/actions/approve", headers: headers, as: :json
    assert_response :unprocessable_entity
    assert @sheet.reload.submitted?
  end

  test 'mobile sessions expire and are invalidated by employee termination password or account changes' do
    headers = app_login
    record = EmployeeAppSession.unscoped.last
    record.update!(expires_at: 1.minute.ago)
    get '/api/v1/employee/session', headers: headers
    assert_response :unauthorized
    headers = app_login
    @user.update!(password: 'changedpassword123')
    get '/api/v1/employee/session', headers: headers
    assert_response :unauthorized
    @user.update!(password: 'password123')
    headers = app_login
    @employee.terminate!
    get '/api/v1/employee/session', headers: headers
    assert_response :unauthorized
  end

  test 'mobile login shares web brute force throttle and rejects cookies alone' do
    5.times do
      post '/api/v1/employee/session', params: { email: @user.email, password: 'wrong' }, as: :json
      assert_response :unauthorized
    end
    post '/api/v1/employee/session', params: { email: @user.email, password: 'password123' }, as: :json
    assert_response :too_many_requests
    sign_in(@admin)
    get '/api/v1/employee/timesheets'
    assert_response :unauthorized
  end

  test 'admin employee setup link works once and is never available to managers' do
    sign_in(@manager)
    post employee_access_path(employee_id: @employee.id)
    assert_response :forbidden
    sign_in(@admin)
    post employee_access_path(employee_id: @employee.id)
    assert_response :success
    assert_equal 'no-store', response.headers['Cache-Control']
    link = css_select('#setup-link').first['value']
    token = URI.decode_www_form(URI(link).query).to_h.fetch('token')
    delete logout_path
    get employee_setup_path(token: token)
    assert_response :success
    patch employee_setup_path, params: { token: token, password: 'newpassword123', password_confirmation: 'newpassword123' }
    assert_response :redirect
    assert @user.reload.authenticate('newpassword123')
    patch employee_setup_path, params: { token: token, password: 'anotherpassword123', password_confirmation: 'anotherpassword123' }
    assert_response :gone
  end

  test 'employee installation manifest icons service worker and devices are served by instance' do
    get employee_app_path
    assert_response :success
    get employee_manifest_path
    assert_response :success
    assert_equal '/employee', JSON.parse(response.body)['start_url']
    assert_equal ['192x192', '512x512'], JSON.parse(response.body)['icons'].map { |icon| icon['sizes'] }
    get '/employee/service-worker.js'
    assert_response :success
    assert_equal '/', response.headers['Service-Worker-Allowed']
    assert_not_includes response.body, 'caches.open'
    headers = app_login
    record = EmployeeAppSession.unscoped.last
    sign_in
    post revoke_employee_device_path(record)
    assert_response :redirect
    get '/api/v1/employee/session', headers: headers
    assert_response :unauthorized
  end

  test 'csv export neutralizes spreadsheet formulas' do
    @employee.update!(first_name: '=HYPERLINK("bad")')
    add_entry
    sign_in
    get people_timesheet_path(@sheet, format: :csv)
    assert_response :success
    assert_includes response.body, "'=HYPERLINK"
  end
  test 'payroll only includes approved entry dates inside the pay run' do
    add_entry(hours: 8, day: '2026-07-27')
    add_entry(hours: 6, day: '2026-07-28')
    @sheet.submit!
    @sheet.approve!
    People::PayRate.create!(employee: @employee, pay_type: 'hourly', hourly_rate_cents: 2000, effective_on: '2026-07-01')
    run = People::PayRun.create!(name: 'Partial week', period_start: '2026-07-28', period_end: '2026-07-28')
    People::PayrollCalculator.generate!(run)
    assert_equal 6, run.payslips.first.hours
    assert_equal 12000, run.payslips.first.gross_cents
  end

  test 'clock changes cannot silently leave stale imported hours and removed dates' do
    Current.user = @user
    shift = ClockShift.create!(employee: @employee, user: @user, employee_key: @employee.id.to_s, employee_name: @employee.name,
      employment_type: 'full_time', started_at: Time.zone.parse('2026-07-27 23:00'), ended_at: Time.zone.parse('2026-07-28 02:00'), request_token: 'clock_corrected_token_123')
    workflow = TimesheetWorkflow.new
    workflow.change(@sheet, :import_shifts)
    shift.update!(started_at: Time.zone.parse('2026-07-28 00:30'))
    assert_raises(TimesheetWorkflow::Error) { workflow.change(@sheet, :submit) }
    workflow.change(@sheet, :import_shifts)
    assert_equal 1, @sheet.entries.count
    assert_equal BigDecimal('1.5'), @sheet.total_hours
    workflow.change(@sheet, :submit)
    assert @sheet.reload.submitted?
  end

  test 'cross tenant API ids and host sign ins cannot expose another workspace' do
    foreign = Tenant.create!(name: 'Second workspace', subdomain: 'second-ts')
    foreign_worker = People::Employee.unscoped.create!(tenant: foreign, first_name: 'Foreign', last_name: 'Worker', employee_number: 'FTS')
    foreign_sheet = People::Timesheet.unscoped.create!(tenant: foreign, employee: foreign_worker, period_start: '2026-07-27', period_end: '2026-08-02')
    headers = app_login
    get "/api/v1/employee/timesheets/#{foreign_sheet.id}", headers: headers
    assert_response :not_found
    host! 'second-ts.example.com'
    post '/api/v1/employee/session', params: { email: @user.email, password: 'password123' }, as: :json
    assert_response :unauthorized
  end

  test 'draft deletion retains records that have submission history' do
    Current.user = @user
    add_entry
    TimesheetWorkflow.new.change(@sheet, :submit)
    Current.user = @manager
    workflow = TimesheetWorkflow.new
    workflow.change(@sheet, :reject)
    workflow.change(@sheet, :reopen)
    assert_raises(TimesheetWorkflow::Error) { workflow.change(@sheet, :destroy) }
    assert People::Timesheet.exists?(@sheet.id)
  end
end
