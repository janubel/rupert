# frozen_string_literal: true

require 'test_helper'

class TimesheetReviewsTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = Tenant.create!(name: 'Review workspace', subdomain: 'review-workspace')
    Current.tenant = @tenant
    @worker = User.create!(tenant: @tenant, email: 'review-worker@example.com', password: 'password123', role: 'employee')
    @reviewer = User.create!(tenant: @tenant, email: 'review-leader@example.com', password: 'password123', role: 'shift_leader')
    @employee = People::Employee.create!(first_name: 'Alex', last_name: 'Worker', user: @worker)
    @other = People::Employee.create!(first_name: 'Other', last_name: 'Worker')
    @sheet = @employee.timesheets.create!(period_start: '2026-07-27', period_end: '2026-08-02')
    @draft = @other.timesheets.create!(period_start: '2026-07-27', period_end: '2026-08-02')
    @entry = @sheet.entries.create!(worked_on: '2026-07-27', hours: 8, work_type: 'regular')
  end

  teardown { Current.reset }

  def sign_in(user = @reviewer)
    post login_path, params: { email: user.email, password: 'password123' }
    Current.tenant = @tenant
  end

  test 'admins managers and shift leaders have a top tab and a submitted review queue' do
    @sheet.submit!
    %w[admin manager shift_leader].each do |role|
      @reviewer.update!(role: role)
      sign_in
      get people_timesheets_path
      assert_response :success
      assert_select 'nav[aria-label="Module areas"] a[href=?][aria-current="page"]', people_timesheets_path, text: 'Timesheets'
      assert_select 'nav[aria-label="Timesheet review"] a', text: 'Needs review (1)'
      assert_select 'a[href=?]', people_timesheet_path(@sheet), text: 'Review timesheet'
      assert_select 'a[href=?]', people_timesheet_path(@draft), count: 0
      get people_timesheets_path(status: 'all')
      assert_select 'a[href=?]', people_timesheet_path(@draft), minimum: 1
      get people_timesheet_path(@sheet)
      assert_select 'input[type="submit"][value="Approve"]'
      assert_select 'input[type="submit"][value="Return for correction"]'
    end
    post approve_people_timesheet_path(@sheet), params: { review_note: 'Hours checked against shifts.' }
    assert @sheet.reload.approved?
    assert_equal @reviewer.id, @sheet.reviewed_by
    assert_equal 'Hours checked against shifts.', @sheet.review_note
    assert_equal ['approve'], @sheet.events.pluck(:action)
    refute @reviewer.reload.can?('payroll.read')
    refute @reviewer.can_manage_accounts?
  end

  test 'shift leader can return hours but cannot edit another employee or review own hours' do
    @sheet.submit!
    sign_in
    post reject_people_timesheet_path(@sheet), params: { review_note: 'Please check Monday.' }
    assert @sheet.reload.rejected?
    assert_equal @reviewer.id, @sheet.reviewed_by
    assert_equal 'Please check Monday.', @sheet.review_note
    sign_in(@worker)
    post reopen_people_timesheet_path(@sheet)
    assert @sheet.reload.draft?
    sign_in
    patch people_timesheet_path(@sheet), params: { timesheet: { notes: 'Changed by leader' } }
    assert_nil @sheet.reload.notes
    @employee.update!(user: @reviewer)
    @sheet.submit!
    post approve_people_timesheet_path(@sheet)
    assert @sheet.reload.submitted?
    assert_nil @sheet.reviewed_by
    get people_timesheets_path
    assert_select 'p', text: 'Another reviewer required'
  end

  test 'cross workspace access and revoked review permission are denied' do
    foreign = Tenant.create!(name: 'Other review workspace', subdomain: 'foreign-review')
    employee = People::Employee.unscoped.create!(tenant: foreign, first_name: 'Private', last_name: 'Worker')
    sheet = People::Timesheet.unscoped.create!(tenant: foreign, employee: employee, period_start: '2026-07-27', period_end: '2026-08-02')
    sign_in
    get people_timesheet_path(sheet)
    assert_response :not_found
    post approve_people_timesheet_path(sheet)
    assert_response :not_found
    @sheet.submit!
    @reviewer.update_permission_overrides!(%w[dashboard.read timesheets.read])
    post approve_people_timesheet_path(@sheet)
    assert @sheet.reload.submitted?
    get people_timesheet_path(@sheet)
    assert_select 'input[type="submit"][value="Approve"]', count: 0
    get people_timesheets_path(status: 'approved')
    assert_select 'nav[aria-label="Timesheet review"]', count: 0
  end

  test 'approval rechecks clock changes and pending corrections since submission' do
    @entry.destroy!
    Current.user = @worker
    shift = ClockShift.create!(employee: @employee, user: @worker, employee_key: @employee.id.to_s, employee_name: @employee.name,
      employment_type: 'full_time', started_at: Time.zone.parse('2026-07-27 09:00'), ended_at: Time.zone.parse('2026-07-27 17:00'), request_token: 'review_clock_token_123')
    workflow = TimesheetWorkflow.new
    workflow.change(@sheet, :import_shifts)
    workflow.change(@sheet, :submit)
    shift.update!(ended_at: shift.ended_at + 1.hour)
    sign_in
    post approve_people_timesheet_path(@sheet)
    assert @sheet.reload.submitted?
    assert_nil @sheet.reviewed_by
    assert_match(/Clock times have changed/, flash[:alert])
    shift.update!(ended_at: shift.ended_at - 1.hour)
    TimeClockService.request_correction(user: @worker, shift_id: shift.id, attributes: { proposed_started_at: shift.started_at, proposed_ended_at: shift.ended_at + 1.hour, reason: 'Check end time' })
    post approve_people_timesheet_path(@sheet)
    assert @sheet.reload.submitted?
    assert_match(/Resolve clock corrections/, flash[:alert])
    assert_equal 0, @sheet.events.where(action: 'approve').count
    post reject_people_timesheet_path(@sheet), params: { review_note: 'Resolve clock correction first.' }
    assert @sheet.reload.rejected?
  end

  test 'submission and approval reject invalid retained entries and inactive employees' do
    @entry.update_columns(hours: 25)
    sign_in(@worker)
    post submit_people_timesheet_path(@sheet)
    assert @sheet.reload.draft?
    assert_match(/24/, flash[:alert])
    @entry.update_columns(hours: 8)
    post submit_people_timesheet_path(@sheet)
    assert @sheet.reload.submitted?
    @employee.terminate!
    sign_in
    post approve_people_timesheet_path(@sheet)
    assert @sheet.reload.submitted?
    assert_nil @sheet.reviewed_by
    assert_match(/no longer active/, flash[:alert])
  end

  test 'admin queue shows hour breakdowns flags search week navigation and missing employees' do
    @sheet.entries.create!(worked_on: '2026-07-28', hours: 3, work_type: 'overtime')
    @sheet.submit!
    sign_in
    get people_timesheets_path(status: 'all', period: '2026-07-28')
    assert_response :success
    assert_select 'section[aria-label="Timesheet summary"]'
    assert_select 'span', text: 'Overtime recorded'
    assert_select 'nav[aria-label="Week"] a', text: /Previous week/
    assert_select 'section[aria-label="Missing timesheets"]', count: 0 # reviewer lacks timesheets.write
    get people_timesheets_path(status: 'all', q: 'alex')
    assert_select 'a[href=?]', people_timesheet_path(@sheet), minimum: 1
    assert_select 'a[href=?]', people_timesheet_path(@draft), count: 0
    get people_timesheet_path(@sheet)
    assert_select 'section[aria-label="Daily hours"]'
  end

  test 'calendar view leads the page with holidays and per-employee toggles' do
    ClockShift.create!(employee: @employee, user: @worker, employee_key: @employee.id.to_s, employee_name: @employee.name,
      employment_type: 'part_time', request_token: 'calendar-token-0001',
      started_at: Time.zone.parse('2026-09-08 09:00'), ended_at: Time.zone.parse('2026-09-08 13:00'))
    sign_in
    get people_timesheets_path(period: '2026-09-07')
    assert_response :success
    assert_select 'section[aria-label="Week calendar"]'
    assert_select 'button[data-employee-id=?]', @employee.id.to_s
    assert_match 'Labor Day', response.body
  end

  test 'calendar shows open punches, unlinked source records and typed hours' do
    ClockShift.create!(employee: @employee, user: @worker, employee_key: @employee.id.to_s, employee_name: @employee.name,
      employment_type: 'part_time', request_token: 'calendar-token-0002', started_at: 2.hours.ago)
    SquareTimecard.create!(external_id: 'sq-1', team_member_id: 'TMXYZ123456', started_at: 3.hours.ago, ended_at: 1.hour.ago,
      import_status: 'unmatched', last_seen_at: Time.current)
    sign_in
    get people_timesheets_path(period: Date.current.beginning_of_week.iso8601)
    assert_select '[aria-label="Clocked in now"]', text: /Alex Worker/
    assert_match 'Unmatched Square', response.body
    get people_timesheets_path(period: '2026-07-27')
    assert_select 'p[data-schedule-filter-target="block"]', text: /Alex Worker 8h/
  end

  test 'bulk approve approves eligible sheets and reports the rest' do
    @sheet.submit!
    own = @other.timesheets.create!(period_start: '2026-08-03', period_end: '2026-08-09')
    sign_in
    post bulk_approve_people_timesheets_path, params: { timesheet_ids: [@sheet.id, @draft.id], review_note: 'ok' }
    assert @sheet.reload.approved?
    assert @draft.reload.draft?
    assert_match(/not available/, flash[:alert])
    post bulk_approve_people_timesheets_path
    assert_match(/Select at least one/, flash[:alert])
    assert own.reload.draft?
  end
end
