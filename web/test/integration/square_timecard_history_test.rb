# frozen_string_literal: true

require 'test_helper'

class SquareTimecardHistoryTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    Current.user = users(:regular_user)
    @admin = Current.user
    @user = User.create!(tenant: @tenant, email: 'square-hours-worker@example.invalid', password: 'password123', role: 'employee')
    @worker = People::Employee.create!(first_name: 'Own', last_name: 'History', user: @user)
    @other = People::Employee.create!(first_name: 'PRIVATE', last_name: 'OTHER WORKER')
    EmployeeSourceIdentity.create!(employee: @worker, source: 'square', external_id: 'own-team')
    EmployeeSourceIdentity.create!(employee: @other, source: 'square', external_id: 'other-team')
    SquareTimecardImport.new(rows: [source('own-card', 'own-team'), source('private-other-card', 'other-team')]).call(apply: true)
    @card = @worker.square_timecards.first
    @other_card = @other.square_timecards.first
  end
  teardown { Current.reset }

  def source(id, team)
    { 'id' => id, 'team_member_id' => team, 'location_id' => 'native-location', 'timezone' => 'America/New_York',
      'start_at' => '2026-10-05T09:00:00-04:00', 'end_at' => '2026-10-05T17:00:00-04:00', 'status' => 'CLOSED',
      'wage' => { 'hourly_rate' => { 'amount' => 2000, 'currency' => 'USD' } } }
  end

  test 'employees can read only their own imported hours calendar history and safe CSV' do
    post login_path, params: { email: @user.email, password: 'password123' }
    get people_timesheets_path
    assert_response :success
    assert_select 'a[href=?]', people_square_timesheets_path
    get people_square_timesheets_path, params: { employee_id: @other.id }
    assert_response :success
    assert_equal 'no-store', response.headers['Cache-Control']
    assert_select 'a[href=?]', people_square_timesheet_path(@card)
    assert_select 'a[href=?]', people_square_timesheet_path(@other_card), count: 0
    refute_includes response.body, 'PRIVATE OTHER WORKER'
    get people_square_timesheet_path(@other_card)
    assert_response :not_found
    get people_square_timesheets_path(format: :csv), params: { employee_id: @other.id }
    assert_response :success
    assert_includes response.body, 'own-card'
    refute_includes response.body, 'private-other-card'
    get employee_reports_path, params: { from: '2026-10-05', to: '2026-10-11', employee_id: @other.id }
    assert_response :success
    assert_includes response.body, 'Square history'
    assert_includes response.body, '$160.00'
    assert_includes response.body, '8h'
    get employee_time_off_path, params: { month: '2026-10' }
    assert_response :success
    assert_select '[role="cell"][aria-label="2026-10-05"]', text: /8h/
    assert_no_difference ['SquareTimecard.count', 'SquareTimecardDay.count', 'People::TimesheetEntry.count'] do
      post people_square_timesheets_path
      assert_response :not_found
      patch people_square_timesheet_path(@card), params: { payable_seconds: 999999 }
      assert_response :not_found
    end
    get sales_path
    assert_response :redirect
  end

  test 'administrator can review matched history without exposing encrypted source payloads' do
    post login_path, params: { email: @admin.email, password: 'password' }
    get people_square_timesheets_path
    assert_response :success
    assert_includes response.body, 'PRIVATE OTHER WORKER'
    get people_square_timesheets_path, params: { employee_id: @worker.id }
    assert_response :success
    refute_includes response.body, 'PRIVATE OTHER WORKER'
    get people_square_timesheet_path(@card)
    assert_response :success
    assert_includes response.body, 'own-card'
    assert_includes response.body, '8.00h'
    refute_includes response.body, '"team_member_id"'
    get people_square_timesheets_path, params: { from: 'invalid-date' }
    assert_redirected_to people_square_timesheets_path
  end

  test 'native history API forces employee ownership and has no write endpoints' do
    post '/api/v1/employee/session', params: { email: @user.email, password: 'password123' }, as: :json
    assert_response :created
    headers = { 'Authorization' => "Bearer #{response.parsed_body.fetch('token')}" }
    get '/api/v1/employee/square_timecards', params: { employee_id: @other.id }, headers: headers
    assert_response :success
    assert_equal ['own-card'], response.parsed_body.fetch('data').map { |row| row['external_id'] }
    refute_includes response.body, 'source_payload'
    get "/api/v1/employee/square_timecards/#{@card.id}", headers: headers
    assert_response :success
    assert_equal 28_800, response.parsed_body.dig('data', 'days', 0, 'payable_seconds')
    get "/api/v1/employee/square_timecards/#{@other_card.id}", headers: headers
    assert_response :not_found
    post '/api/v1/employee/square_timecards', headers: headers, as: :json
    assert_response :not_found
    get '/api/v1/employee/square_timecards'
    assert_response :unauthorized
  end

  test 'local clock and entry workflows cannot duplicate imported source intervals' do
    Current.tenant = @tenant
    Current.user = @user
    assert_raises(ActiveRecord::RecordInvalid) do
      ClockShift.create!(user: @user, employee: @worker, employee_key: @worker.id.to_s, employee_name: @worker.name,
        employment_type: @worker.employment_type, request_token: 'square_overlap_forbidden', started_at: '2026-10-05T10:00:00-04:00', ended_at: '2026-10-05T11:00:00-04:00')
    end
    shift = ClockShift.create!(user: @user, employee: @worker, employee_key: @worker.id.to_s, employee_name: @worker.name,
      employment_type: @worker.employment_type, request_token: 'square_nonoverlap_allowed', started_at: '2026-10-05T18:00:00-04:00', ended_at: '2026-10-05T20:00:00-04:00')
    sheet = TimesheetWorkflow.new.create(employee_id: @worker.id, period_start: '2026-10-05', period_end: '2026-10-11')
    assert_raises(ActiveRecord::RecordInvalid) { TimesheetWorkflow.new.change(sheet, :add_entry, worked_on: '2026-10-05', hours: 8) }
    TimesheetWorkflow.new.change(sheet, :import_shifts)
    assert_equal [shift.id], sheet.entries.pluck(:clock_shift_id)
    summary = EmployeeWorkSummary.new(employee: @worker, from: Date.new(2026, 10, 5), to: Date.new(2026, 10, 5))
    assert_equal 10, summary.hours
    # A later import holds a new overlapping source timecard and retains existing hours.
    Current.user = @admin
    result = SquareTimecardImport.new(rows: [source('own-card', 'own-team'), source('new-overlap', 'own-team').merge('start_at' => '2026-10-05T18:00:00-04:00', 'end_at' => '2026-10-05T20:00:00-04:00')]).call(apply: true)
    assert_equal 1, result[:statuses]['conflict']
    assert_equal 10, EmployeeWorkSummary.new(employee: @worker, from: Date.new(2026, 10, 5), to: Date.new(2026, 10, 5)).hours
  end

  test 'further profile consolidation moves source history without losing native IDs or daily hours' do
    Current.tenant = @tenant
    Current.user = @admin
    primary = People::Employee.create!(first_name: 'Canonical', last_name: 'Worker')
    EmployeeConsolidation.call(primary_id: primary.id, duplicate_ids: [@other.id], reason: 'Confirmed same employee')
    assert_equal primary.id, @other_card.reload.employee_id
    assert_equal 'private-other-card', @other_card.external_id
    assert_equal 28_800, primary.square_timecard_days.sum(:payable_seconds)
    assert_equal primary.id, EmployeeSourceIdentity.find_by!(external_id: 'other-team').employee_id
  end
end
