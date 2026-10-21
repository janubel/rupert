# frozen_string_literal: true

require 'test_helper'

class PunchHistoryTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    @admin = users(:regular_user)
    @user = User.create!(tenant: @tenant, email: 'punch-history-worker@example.invalid', password: 'password123', role: 'employee')
    @worker = People::Employee.create!(first_name: 'Own', last_name: 'History', user: @user)
    @other = People::Employee.create!(first_name: 'PRIVATE', last_name: 'OTHER WORKER')
    EmployeeSourceIdentity.create!(employee: @worker, source: 'square', external_id: 'own-team')
    EmployeeSourceIdentity.create!(employee: @other, source: 'square', external_id: 'other-team')
    SquareTimecardImport.new(actor: @admin, rows: [source('own-card', 'own-team'), source('private-other-card', 'other-team')]).call(apply: true)
    @card = @worker.square_timecards.first
    @other_card = @other.square_timecards.first
    @shift = ClockShift.create!(user: @user, employee: @worker, employee_key: @worker.id.to_s,
      employee_name: @worker.name, employment_type: 'part_time', request_token: 'punch_history_token_123',
      started_at: Time.zone.parse('2026-10-06 18:00'), ended_at: Time.zone.parse('2026-10-06 19:00'))
  end
  teardown { Current.reset }

  def source(id, team)
    { 'id' => id, 'team_member_id' => team, 'location_id' => 'native-location', 'timezone' => 'America/New_York',
      'start_at' => '2026-10-06T09:00:00-04:00', 'end_at' => '2026-10-06T17:00:00-04:00', 'status' => 'CLOSED',
      'wage' => { 'hourly_rate' => { 'amount' => 2000, 'currency' => 'USD' } } }
  end

  test 'administrator sees every punch source with calendar and list views' do
    post login_path, params: { email: @admin.email, password: 'password' }
    get people_punch_history_path, params: { from: '2026-10-01', to: '2026-10-31' }
    assert_response :success
    assert_equal 'no-store', response.headers['Cache-Control']
    assert_includes response.body, 'Own History'
    assert_includes response.body, 'PRIVATE OTHER WORKER'
    assert_select 'a[href=?]', people_punch_history_path(request.query_parameters.merge(view: 'calendar'))
    assert_includes response.body, 'Rupert'
    assert_includes response.body, 'Square'

    get people_punch_history_path, params: { from: '2026-10-01', to: '2026-10-31', view: 'calendar' }
    assert_response :success
    assert_select '[data-punch-calendar-target="day"][data-date="2026-10-06"]'

    get people_punch_history_path, params: { from: '2026-10-01', to: '2026-10-31', source: 'rupert' }
    assert_response :success
    assert_includes response.body, 'Clock shift'
    refute_includes response.body, 'own-card'
  end

  test 'employees see only their own punches' do
    post login_path, params: { email: @user.email, password: 'password123' }
    get people_punch_history_path, params: { from: '2026-10-01', to: '2026-10-31' }
    assert_response :success
    assert_includes response.body, 'Own History'
    refute_includes response.body, 'PRIVATE OTHER WORKER'
    refute_includes response.body, 'private-other-card'
    get people_punch_history_path(format: :csv), params: { from: '2026-10-01', to: '2026-10-31', employee_id: @other.id }
    assert_response :success
    refute_includes response.body, 'PRIVATE OTHER WORKER'
    refute_includes response.body, 'private-other-card'
  end

  test 'csv report exports only visible punches and never writes records' do
    post login_path, params: { email: @admin.email, password: 'password' }
    assert_no_difference ['ClockShift.count', 'SquareTimecard.count', 'SquareTimecardDay.count', 'People::TimesheetEntry.count'] do
      get people_punch_history_path(format: :csv), params: { from: '2026-10-01', to: '2026-10-31' }
      assert_response :success
      assert_includes response.body, 'own-card'
      assert_includes response.body, 'Clock shift'
      assert_includes response.body, 'PRIVATE OTHER WORKER'
    end
  end

  test 'c-trax shifts appear uncounted, long punches are flagged and presets filter the range' do
    payload = { started_at: '2026-10-07T09:00:00-04:00', ended_at: '2026-10-08T09:30:00-04:00', number_of_hours: 24.5,
      is_in_progress: false, is_verified: false }.to_json
    CtraxLaborShift.create!(source_origin: 'https://source.example.invalid', external_id: 'ctrax-long', store_id: 'store-one',
      user_external_id: 'user-long', employee: @worker, status: 'imported', last_seen_at: Time.current, original_digest: 'o', latest_digest: 'l',
      started_at: '2026-10-07T09:00:00-04:00', ended_at: '2026-10-08T09:30:00-04:00', reported_hours: 24.5, elapsed_hours: 24.5,
      in_progress: false, verified: false, source_payload: payload, latest_payload: payload)
    post login_path, params: { email: @admin.email, password: 'password' }
    get people_punch_history_path, params: { from: '2026-10-01', to: '2026-10-31' }
    assert_response :success
    assert_includes response.body, 'C-Trax ctrax-long'
    assert_includes response.body, 'missed clock-out'
    assert_select 'nav[aria-label="Time workspace"] a', text: 'Punch report'
    assert_select 'nav[aria-label="Time workspace"] a', text: 'Timesheets'
    assert_select 'select#range option', text: 'This pay week'
    assert_select '[data-time-source="ctrax"]'

    history = PunchHistory.new(from: Date.new(2026, 10, 1), to: Date.new(2026, 10, 31), all_employees: true)
    ctrax = history.rows.find { |row| row.source == 'ctrax' }
    assert ctrax.implausible?
    refute ctrax.counted
    assert_equal 1, history.summary.implausible
    assert_equal 0.0, history.summary.by_employee_source.fetch('Own History').fetch('ctrax') - 24.5
    # C-Trax hours never enter counted totals.
    assert_equal 17.0, history.summary.counted_hours

    get people_punch_history_path, params: { from: '2026-10-01', to: '2026-10-31', source: 'ctrax' }
    assert_response :success
    assert_includes response.body, 'ctrax-long'
    refute_includes response.body, 'Clock shift #'

    get people_punch_history_path(format: :csv), params: { from: '2026-10-01', to: '2026-10-31' }
    assert_includes response.body, 'C-Trax'
    assert_includes response.body, 'missed clock-out'
  end

  test 'punch report uses the shared range picker without inline scripts' do
    travel_to Time.zone.parse('2026-10-20 12:00') do # Tuesday; pay week began Thursday Oct 15
      post login_path, params: { email: @admin.email, password: 'password' }
      get people_punch_history_path, params: { range: 'this_pay_week', source: 'square', view: 'calendar' }
      assert_response :success
      assert_select 'select#range option[selected][value="this_pay_week"]', 'This pay week'
      assert_select 'input[type=date][name=from][value="2026-10-15"][data-punch-calendar-target="from"]'
      assert_select 'input[type=date][name=to][value="2026-10-21"][data-punch-calendar-target="to"]'
      assert_select 'input[type=hidden][name=range_shown][value="2026-10-15..2026-10-21"]'
      assert_select 'select#source option[selected][value="square"]'
      assert_select '[onchange]', 0
      assert_select 'a[href=?]', people_punch_history_path(source: 'square', view: 'calendar', from: '2026-10-15', to: '2026-10-21', format: :csv)

      # Without JavaScript the dates typed into Start/Finish win over the dropdown left as shown.
      get people_punch_history_path, params: { range: 'this_pay_week', range_shown: '2026-10-15..2026-10-21', from: '2026-10-01', to: '2026-10-31' }
      assert_includes response.body, 'Own History'
      assert_select 'select#range option[selected][value="this_month"]'
    end
  end

  test 'square, c-trax and personal reports share the range picker' do
    travel_to Time.zone.parse('2026-10-20 12:00') do
      post login_path, params: { email: @admin.email, password: 'password' }
      get people_square_timesheets_path
      assert_response :success
      assert_select 'select#range option[selected][value="all"]', 'All dates'
      assert_select 'input[type=date][name=from]:not([required])'
      get people_square_timesheets_path, params: { range: 'last_pay_week' }
      assert_select 'input[name=from][value="2026-10-08"]'
      assert_includes response.body, 'No Square timecards in this view.'
      get people_square_timesheets_path, params: { range: 'custom', from: '2026-10-06', to: '2026-10-06' }
      refute_includes response.body, 'No Square timecards in this view.'
      get people_ctrax_timesheets_path, params: { range: 'this_month' }
      assert_response :success
      assert_select 'input[name=to][value="2026-10-31"]'
      get people_ctrax_timesheets_path, params: { from: '2026-10-09', to: '2026-10-01' }
      assert_redirected_to people_ctrax_timesheets_path

      post login_path, params: { email: @user.email, password: 'password123' }
      get employee_reports_path, params: { range: 'last_pay_week' }
      assert_response :success
      assert_select 'select#range option[selected][value="last_pay_week"]'
      assert_select 'a[href=?]', employee_reports_path(format: :csv, from: '2026-10-08', to: '2026-10-14')
    end
  end

  test 'reversed ranges are rejected and no record is created' do
    post login_path, params: { email: @admin.email, password: 'password' }
    assert_no_difference ['ClockShift.count', 'SquareTimecard.count'] do
      get people_punch_history_path, params: { from: '2026-10-31', to: '2026-10-01' }
      assert_response :redirect
    end
    get people_punch_history_path, params: { from: 'not-a-date' }
    assert_response :redirect
  end
end
