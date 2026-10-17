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
    SquareTimecardImport.new(rows: [source('own-card', 'own-team'), source('private-other-card', 'other-team')]).call(apply: true)
    @card = @worker.square_timecards.first
    @other_card = @other.square_timecards.first
    @shift = ClockShift.create!(user: @user, employee: @worker, employee_key: @worker.id.to_s,
      employee_name: @worker.name, employment_type: 'part_time', request_token: 'punch_history_token_123',
      started_at: Time.zone.parse('2026-10-06 09:00'), ended_at: Time.zone.parse('2026-10-06 17:00'))
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
