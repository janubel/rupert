# frozen_string_literal: true

require 'test_helper'

class TimeKeepingTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    @admin = users(:regular_user)
    @user = User.create!(tenant: @tenant, email: 'time-keeping-worker@example.invalid', password: 'password123', role: 'employee')
    @worker = People::Employee.create!(first_name: 'Own', last_name: 'Keeper', user: @user)
    @other = People::Employee.create!(first_name: 'PRIVATE', last_name: 'COWORKER')
    EmployeeSourceIdentity.create!(employee: @worker, source: 'square', external_id: 'tk-own')
    EmployeeSourceIdentity.create!(employee: @other, source: 'square', external_id: 'tk-other')
    SquareTimecardImport.new(actor: @admin, rows: [card('tk-own-card', 'tk-own'), card('tk-other-card', 'tk-other')]).call(apply: true)
    ClockShift.create!(user: @user, employee: @worker, employee_key: @worker.id.to_s, employee_name: @worker.name,
      employment_type: 'part_time', request_token: 'time_keeping_token_123',
      started_at: Time.zone.parse('2026-10-06 18:00'), ended_at: Time.zone.parse('2026-10-06 19:00'))
    People::ScheduledShift.create!(employee: @worker, starts_at: Time.zone.parse('2026-10-06 09:00'), ends_at: Time.zone.parse('2026-10-06 17:00'), role_label: 'Floor')
    People::ScheduledShift.create!(employee: @other, starts_at: Time.zone.parse('2026-10-07 10:00'), ends_at: Time.zone.parse('2026-10-07 14:00'))
  end
  teardown { Current.reset }

  def card(id, team)
    { 'id' => id, 'team_member_id' => team, 'location_id' => 'native-location', 'timezone' => 'America/New_York',
      'start_at' => '2026-10-06T09:00:00-04:00', 'end_at' => '2026-10-06T17:00:00-04:00', 'status' => 'CLOSED',
      'wage' => { 'hourly_rate' => { 'amount' => 2000, 'currency' => 'USD' } } }
  end

  def report(**options)
    TimeKeepingReport.new(from: Date.new(2026, 10, 1), to: Date.new(2026, 10, 31), all_employees: true, **options)
  end

  test 'compares scheduled with counted hours and names each person-day' do
    days = report.days.index_by { |day| [day.employee_id, day.date] }
    own = days.fetch([@worker.id, Date.new(2026, 10, 6)])
    assert_equal [8.0, 9.0, 1.0], [own.scheduled_hours, own.worked_hours, own.variance]
    assert_equal 'Over schedule', own.status
    assert_equal 'Unscheduled', days.fetch([@other.id, Date.new(2026, 10, 6)]).status
    assert_equal 'No punches', days.fetch([@other.id, Date.new(2026, 10, 7)]).status
    staff = report.staff.index_by(&:employee_id)
    assert_equal 1, staff.fetch(@other.id).no_punch_days
    assert_equal({ scheduled: 12.0, worked: 17.0 }, report.totals.slice(:scheduled, :worked))
    assert_equal [@worker.id], report(employee_id: @worker.id.to_s).staff.map(&:employee_id)
    assert_raises(TimeKeepingReport::Error) { TimeKeepingReport.new(from: Date.new(2026, 10, 2), to: Date.new(2026, 10, 1)) }
  end

  test 'Team shows Time keeping with calendar, roster, daily and staff views plus CSV and PDF' do
    post login_path, params: { email: @admin.email, password: 'password' }
    range = { from: '2026-10-01', to: '2026-10-31' }
    get people_time_keeping_path, params: range
    assert_response :success
    assert_equal 'no-store', response.headers['Cache-Control']
    assert_select 'h1', 'Time keeping'
    assert_select 'table.time-keeping-calendar', /Own Keeper/
    assert_select 'nav[aria-label="Time keeping views"] a', 4

    %w[roster daily staff].each do |view|
      get people_time_keeping_path, params: range.merge(view: view)
      assert_response :success
      assert_select '[data-controller=report-table] table', /PRIVATE COWORKER/
    end
    get people_time_keeping_path, params: range.merge(view: 'daily')
    assert_includes response.body, 'No punches'

    assert_no_difference ['ClockShift.count', 'SquareTimecard.count', 'People::ScheduledShift.count', 'People::Timesheet.count'] do
      get people_time_keeping_path(format: :csv), params: range.merge(kind: 'staff')
      assert_response :success
      assert_equal 'text/csv', response.media_type
      assert_includes response.body, 'Scheduled hours'
      assert_includes response.body, 'Own Keeper'
      get people_time_keeping_path(format: :pdf), params: range
      assert_response :success
      assert_equal 'application/pdf', response.media_type
      assert response.body.start_with?('%PDF')
    end

    get people_time_keeping_path, params: { from: '2026-10-09', to: '2026-10-01' }
    assert_redirected_to people_time_keeping_path
  end

  test 'range picker offers named ranges with Start and Finish calendars' do
    travel_to Time.zone.parse('2026-10-20 12:00') do # Tuesday; pay week began Thursday Oct 15
      post login_path, params: { email: @admin.email, password: 'password' }
      get people_time_keeping_path, params: { from: '2026-10-01', to: '2026-10-31', view: 'daily' }
      assert_response :success
      assert_select '[data-controller="range-picker"]' do
        assert_select 'label[for="range"]', 'Date range'
        assert_select 'select#range[name="range"] option', 14
        assert_select 'select#range option[selected][value="this_month"]', 'This month'
        %w[today yesterday this_pay_week last_pay_week next_pay_week this_week last_week this_month last_month this_quarter
           last_quarter year_to_date last_year custom].each { |key| assert_select "select#range option[value=#{key}]" }
        assert_select 'label[for="from"]', 'Start date'
        assert_select 'label[for="to"]', 'End date'
        assert_select 'input[type=date][name=from][value="2026-10-01"][aria-describedby="time-range-error"]'
        assert_select 'input[type=date][name=to][value="2026-10-31"][aria-describedby="time-range-error"]'
        assert_select '#time-range-error[role=alert]'
      end

      get people_time_keeping_path, params: { range: 'last_pay_week', view: 'daily' }
      assert_response :success
      assert_select 'input[name=from][value="2026-10-08"]'
      assert_select 'input[name=to][value="2026-10-14"]'
      assert_select 'select#range option[selected][value="last_pay_week"]'
      assert_select 'a[href=?]', people_time_keeping_path(from: '2026-10-08', to: '2026-10-14', format: :pdf)

      get people_time_keeping_path, params: { range: 'next_pay_week' }
      assert_select 'input[name=from][value="2026-10-22"]'
      assert_select 'input[name=to][value="2026-10-28"]'

      get people_time_keeping_path, params: { range: 'custom', from: '2026-10-05', to: '2026-10-07', range_shown: '2026-10-01..2026-10-31' }
      assert_select 'input[name=from][value="2026-10-05"]'
      assert_select 'select#range option[selected][value="custom"]'

      get people_time_keeping_path(format: :csv), params: { range: 'last_pay_week', kind: 'daily' }
      assert_includes response.headers['Content-Disposition'], '2026-10-08-to-2026-10-14'
    end
  end

  test 'staff see only their own schedule and time' do
    post login_path, params: { email: @user.email, password: 'password123' }
    get people_time_keeping_path, params: { from: '2026-10-01', to: '2026-10-31', view: 'daily', employee_id: @other.id }
    assert_response :success
    assert_includes response.body, 'Own Keeper'
    refute_includes response.body, 'PRIVATE COWORKER'
    get people_time_keeping_path(format: :csv), params: { from: '2026-10-01', to: '2026-10-31', kind: 'shifts' }
    refute_includes response.body, 'PRIVATE COWORKER'
  end

  test 'Time keeping sits in the Team area' do
    assert_equal 'team', ModuleRegistry.area_key_for('time_keeping')
  end

  test 'an open clock-in is shown but never counted, and a long one reads as a missed clock-out' do
    ClockShift.create!(user: @user, employee: @worker, employee_key: @worker.id.to_s, employee_name: @worker.name,
      employment_type: 'part_time', request_token: 'time_keeping_open_123', started_at: Time.zone.parse('2026-10-09 10:00'))
    day = report.days.find { |d| d.employee_id == @worker.id && d.date == Date.new(2026, 10, 9) }
    assert_equal 0.0, day.worked_hours
    assert_equal 'Missed clock-out', day.status
    open_row = PunchHistory.new(from: Date.new(2026, 10, 9), to: Date.new(2026, 10, 9), all_employees: true).rows.find { |r| r.status == 'open' }
    assert_not open_row.counted
    assert_match(/not counted/, open_row.issue)
    assert_equal 17.0, report.totals[:worked], 'totals exclude the open shift'
  end
end
