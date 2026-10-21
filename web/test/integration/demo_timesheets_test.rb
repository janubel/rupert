# frozen_string_literal: true

require 'test_helper'

class DemoTimesheetsTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    @actor = users(:regular_user)
    Current.user = @actor
    @owner = User.create!(tenant: @tenant, email: 'demo-worker@example.com', name: 'Demo Worker', password: 'password123', role: 'employee')
    @reviewer = User.create!(tenant: @tenant, email: 'assigned-reviewer@example.com', name: 'Assigned Reviewer', password: 'password123', role: 'employee')
    @worker = People::Employee.create!(user: @owner, first_name: 'Demo', last_name: 'Worker')
    @other = People::Employee.create!(first_name: 'Private', last_name: 'Worker')
    @monday = Date.current.beginning_of_week - 14
    @real_sheet = @other.timesheets.create!(period_start: @monday, period_end: @monday + 6)
    @real_sheet.entries.create!(worked_on: @monday, hours: 8, work_type: 'regular')
    @sheets = provision
  end

  teardown { Current.reset }

  def provision
    DemoTimesheetProvisioner.call(user: @owner, reviewer: @reviewer, actor: @actor)
  end

  def sign_in(user)
    post login_path, params: { email: user.email, password: 'password123' }
    Current.tenant = @tenant
  end

  test 'two submitted sample weeks have a demo header and remain private to the owner' do
    assert_equal [40, 38], @sheets.map(&:total_hours)
    assert @sheets.all? { |sheet| sheet.demo? && sheet.submitted? && sheet.assigned_reviewer_id == @reviewer.id }
    assert_equal 10, @worker.timesheet_entries.count
    sign_in(@owner)
    get people_timesheets_path
    assert_response :success
    get people_timesheet_path(@sheets.first)
    assert_select '[aria-label="Demo timesheet notice"]', text: /DEMO.*Fictional timesheet/
    get people_timesheets_path(view: 'list')
    assert_select 'a[href=?]', people_timesheet_path(@real_sheet), count: 0
    get people_timesheet_path(@sheets.first)
    assert_response :success
    assert_includes response.body, 'Assigned to Assigned Reviewer'
    get people_timesheet_path(@sheets.first, format: :csv)
    assert_response :success
    assert_includes response.body, 'DEMO: fictional hours; excluded from payroll'
    get people_timesheet_path(@real_sheet)
    assert_response :not_found
    post approve_people_timesheet_path(@sheets.first)
    assert @sheets.first.reload.submitted?
    assert_equal 'employee', @owner.reload.role
    assert @owner.can_use_pos?
  end

  test 'sample weeks carry fictional sales and card redemptions for the compensation display' do
    first, last = @sheets
    assert_equal [120_000, 96_000], @sheets.map(&:sales_cents)
    assert_equal [3, 2], @sheets.map(&:card_redemptions)
    # 1% commission + $10 per card redemption, display figures only.
    assert_equal [1200, 960], @sheets.map(&:commission_cents)
    assert_equal [3000, 2000], @sheets.map(&:card_bonus_cents)
    assert_equal [4200, 2960], @sheets.map(&:compensation_total_cents)
    sign_in(@owner)
    get people_timesheet_path(first, format: :csv)
    assert_includes response.body, '120000,1200,3,3000,4200'
  end

  test 'assigned employee reviewer can approve or return only the assigned demo records' do
    sign_in(@reviewer)
    get people_timesheets_path
    assert_response :success
    assert_select 'select[name=status][aria-label="Timesheet review"]'
    get people_timesheet_path(@sheets.first)
    assert_response :success
    assert_select 'form[action=?]', approve_people_timesheet_path(@sheets.first)
    post approve_people_timesheet_path(@sheets.first), params: { review_note: 'Demo review completed.' }
    assert @sheets.first.reload.approved?
    assert_equal @reviewer.id, @sheets.first.reviewed_by
    post reject_people_timesheet_path(@sheets.last), params: { review_note: 'Demo correction requested.' }
    assert @sheets.last.reload.rejected?
    get people_timesheet_path(@real_sheet)
    assert_response :not_found
    post approve_people_timesheet_path(@real_sheet)
    assert @real_sheet.reload.draft?
    assert_equal 'employee', @reviewer.reload.role
    refute @reviewer.can?('timesheets.read')
    refute @reviewer.can?('timesheets.write')
    get users_path
    assert_response :redirect
  end

  test 'approved demo hours never enter payroll or actual hours reports' do
    @worker.pay_rates.create!(effective_on: @monday, pay_type: 'hourly', hourly_rate_cents: 2000, pay_frequency: 'weekly')
    @other.pay_rates.create!(effective_on: @monday, pay_type: 'hourly', hourly_rate_cents: 2000, pay_frequency: 'weekly')
    workflow = TimesheetWorkflow.new(user: @actor)
    @sheets.each { |sheet| workflow.change(sheet, :approve) }
    workflow.change(@real_sheet, :submit)
    workflow.change(@real_sheet, :approve)
    run = People::PayRun.create!(name: 'Actual payroll', period_start: @monday, period_end: @monday + 13)
    People::PayrollCalculator.generate!(run)
    assert_equal [@other.id], run.payslips.pluck(:employee_id)
    assert_equal 8, run.payslips.first.hours
    summary = EmployeeWorkSummary.new(employee: @worker, from: @monday, to: @monday + 13)
    assert_empty summary.entries
    assert_equal 0, summary.hours
    assert_empty summary.csv.lines.drop(1)
    assert @sheets.all?(&:demo?)
  end

  test 'provisioning is idempotent and cannot replace real periods or reset reviewed demos' do
    TimesheetWorkflow.new(user: @actor).change(@sheets.first, :approve)
    assert_no_difference ['People::Timesheet.count', 'People::TimesheetEntry.count', 'People::TimesheetEvent.count'] do
      assert_equal @sheets.map(&:id), provision.map(&:id)
    end
    assert @sheets.first.reload.approved?
    @sheets.each(&:destroy!)
    @worker.timesheets.create!(period_start: @monday + 7, period_end: @monday + 13)
    assert_no_difference ['People::Timesheet.count', 'People::TimesheetEntry.count'] do
      assert_raises(ArgumentError) { provision }
    end
  end

  test 'demo identity cannot be cleared and real clock shifts cannot be imported into a demo' do
    workflow = TimesheetWorkflow.new(user: @actor)
    sheet = @sheets.first
    refute sheet.update(demo: false)
    assert sheet.reload.demo?
    workflow.change(sheet, :reject)
    workflow.change(sheet, :reopen)
    assert_raises(TimesheetWorkflow::Error) { workflow.change(sheet, :import_shifts) }
  end

  test 'cross workspace and self review assignment are rejected without creating samples' do
    assert_raises(ArgumentError) { DemoTimesheetProvisioner.call(user: @owner, reviewer: @owner, actor: @actor) }
    other_tenant = Tenant.create!(name: 'Other workspace', subdomain: 'other-demo-review')
    outsider = User.create!(tenant: other_tenant, email: 'outside@example.com', password: 'password123', role: 'employee')
    assert_raises(ArgumentError) { DemoTimesheetProvisioner.call(user: @owner, reviewer: outsider, actor: @actor) }
  end

  test 'browser requests cannot forge the demo flag or reviewer assignment' do
    sign_in(@owner)
    post people_timesheets_path, params: { timesheet: { period_start: @monday - 7, period_end: @monday - 1, demo: true, assigned_reviewer_id: @reviewer.id } }
    created = @worker.timesheets.order(:id).last
    refute created.demo?
    assert_nil created.assigned_reviewer_id
    @real_sheet.update!(submitted_at: Time.current)
    @real_sheet.submit!
    sign_in(@reviewer)
    post approve_people_timesheet_path(@real_sheet)
    assert @real_sheet.reload.submitted?
    patch people_timesheet_path(@sheets.first), params: { timesheet: { notes: 'Reviewer cannot rewrite hours.' } }
    refute_equal 'Reviewer cannot rewrite hours.', @sheets.first.reload.notes
  end

  test 'employee API identifies samples and cannot grant review access' do
    post '/api/v1/employee/session', params: { email: @owner.email, password: 'password123', device_name: 'Demo check' }, as: :json
    assert_response :created
    headers = { 'Authorization' => "Bearer #{response.parsed_body.fetch('token')}" }
    get '/api/v1/employee/timesheets', headers: headers
    assert_response :success
    assert response.parsed_body.fetch('data').all? { |sheet| sheet.fetch('demo') }
    get "/api/v1/employee/timesheets/#{@real_sheet.id}", headers: headers
    assert_response :not_found
  end
end
