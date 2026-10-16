# frozen_string_literal: true

require 'test_helper'

class TimeClockTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    @admin = users(:regular_user)
    @user = User.create!(tenant: @tenant, name: 'Remote worker', email: 'clock-worker@example.com', role: 'cashier', password: 'password')
    @worker = People::Employee.create!(user: @user, first_name: 'Remote', last_name: 'Worker', employment_type: 'contractor')
    login(@user)
  end

  teardown { Current.reset }

  test 'remote worker can clock own shift with safe duplicate requests' do
    travel_to Time.zone.parse('2026-10-10 09:00:00') do
      get time_clock_path
      assert_response :success
      assert_select 'button', 'Clock in'
      token = SecureRandom.uuid
      assert_difference -> { ClockShift.count }, 1 do
        2.times { post clock_in_time_clock_path, params: { request_token: token } }
      end
      shift = ClockShift.first
      assert_equal @worker.id, shift.employee_id
      assert_equal @user.id, shift.user_id
      assert_equal 'contractor', shift.employment_type
      assert_no_difference -> { ClockShift.count } do
        post clock_in_time_clock_path, params: { request_token: SecureRandom.uuid }
      end
      travel 2.hours
      post clock_out_time_clock_path, params: { shift_id: shift.id }
      assert_redirected_to time_clock_path
      ended_at = shift.reload.ended_at
      assert_equal 2, shift.hours
      travel 1.hour
      post clock_out_time_clock_path, params: { shift_id: shift.id }
      assert_equal ended_at, shift.reload.ended_at
    end
  end

  test 'missing worker setup and inactive worker cannot open a shift' do
    @worker.terminate!
    get time_clock_path
    assert_response :success
    assert_select 'h2', 'Link your worker record'
    assert_no_difference -> { ClockShift.count } do
      post clock_in_time_clock_path, params: { request_token: SecureRandom.uuid }
    end
    assert_redirected_to time_clock_path
  end

  test 'own open shift can still close after worker record becomes inactive' do
    post clock_in_time_clock_path, params: { request_token: SecureRandom.uuid }
    shift = ClockShift.first
    @worker.terminate!
    get time_clock_path
    assert_response :success
    assert_select 'button', 'Clock out'
    post clock_out_time_clock_path, params: { shift_id: shift.id }
    assert_redirected_to time_clock_path
    assert shift.reload.ended_at.present?
  end

  test 'other workers and tenants cannot mutate or view own shift history' do
    shift = create_shift
    other_user = User.create!(tenant: @tenant, email: 'other-clock@example.com', role: 'cashier', password: 'password')
    login(other_user)
    get time_clock_path
    assert_response :success
    assert_not_includes response.body, 'Request a time correction'
    post clock_out_time_clock_path, params: { shift_id: shift.id }
    assert_response :not_found
    post request_correction_time_clock_path(shift), params: proposal
    assert_response :not_found
    other_tenant = Tenant.create!(name: 'Private time clock', subdomain: 'private-time-clock')
    other_user.update!(tenant: other_tenant)
    post clock_out_time_clock_path, params: { shift_id: shift.id }
    assert_response :not_found
    assert_equal Time.zone.parse('2026-10-10 11:00:00'), shift.reload.ended_at
  end

  test 'correction needs reviewer permission and retains original audit values' do
    shift = create_shift
    post request_correction_time_clock_path(shift), params: proposal
    assert_redirected_to time_clock_path
    correction = ClockCorrection.first
    assert_equal 'pending', correction.status
    assert_equal Time.zone.parse('2026-10-10 09:00:00'), shift.reload.started_at
    post approve_correction_time_clock_path(correction)
    assert_response :redirect
    assert_equal 'pending', correction.reload.status
    login(@admin)
    assert_no_difference -> { People::Timesheet.count + People::Payslip.count } do
      post approve_correction_time_clock_path(correction)
    end
    assert_redirected_to time_clock_path
    assert_equal 'approved', correction.reload.status
    assert_equal @admin.id, correction.reviewed_by_id
    assert_equal @user.id, correction.requested_by_id
    assert_equal Time.zone.parse('2026-10-10 09:00:00'), correction.original_started_at
    assert_equal Time.zone.parse('2026-10-10 08:00:00'), shift.reload.started_at
    assert_equal Time.zone.parse('2026-10-10 10:00:00'), shift.ended_at
    post approve_correction_time_clock_path(correction)
    assert_equal 'approved', correction.reload.status
  end

  test 'rejection preserves times and stale correction cannot overwrite a later change' do
    shift = create_shift
    post request_correction_time_clock_path(shift), params: proposal
    correction = ClockCorrection.first
    login(@admin)
    post reject_correction_time_clock_path(correction)
    assert_equal 'rejected', correction.reload.status
    assert_equal Time.zone.parse('2026-10-10 09:00:00'), shift.reload.started_at
    login(@user)
    post request_correction_time_clock_path(shift), params: proposal
    newer = ClockCorrection.order(:id).last
    shift.reload.update!(ended_at: Time.zone.parse('2026-10-10 12:00:00'))
    login(@admin)
    post approve_correction_time_clock_path(newer)
    assert_redirected_to time_clock_path
    assert_equal 'pending', newer.reload.status
    assert_equal Time.zone.parse('2026-10-10 12:00:00'), shift.reload.ended_at
  end

  test 'negative future and overlapping corrections are rejected' do
    shift = create_shift
    bad = proposal
    bad[:clock_correction][:proposed_ended_at] = '2026-10-10T07:00:00'
    assert_no_difference -> { ClockCorrection.count } do
      post request_correction_time_clock_path(shift), params: bad
    end
    shift2 = create_shift(started_at: '2026-10-10 12:00:00', ended_at: '2026-10-10 13:00:00')
    post request_correction_time_clock_path(shift2), params: proposal
    correction = ClockCorrection.first
    login(@admin)
    post approve_correction_time_clock_path(correction)
    assert_equal 'pending', correction.reload.status
    assert_equal Time.zone.parse('2026-10-10 12:00:00'), shift2.reload.started_at
  end

  test 'refreshing commission frame does not reference its own source again' do
    login(@admin)
    get commission_preview_time_clock_path, headers: { 'Turbo-Frame' => 'commission-preview' }
    assert_response :success
    assert_select 'turbo-frame#commission-preview[src]', count: 0
    assert_select 'turbo-frame#commission-preview h1', text: 'Commission preview'
  end

  test 'commission preview requires payroll read and validates window' do
    get commission_preview_time_clock_path
    assert_response :redirect
    login(@admin)
    get commission_preview_time_clock_path
    assert_response :success
    assert_select 'h1', 'Commission preview'
    assert_select 'p', /Estimate basis/
    get commission_preview_time_clock_path, params: { start_date: 'invalid' }
    assert_response :unprocessable_entity
    get commission_preview_time_clock_path, params: { start_date: '2026-01-01', end_date: '2026-10-01' }
    assert_response :unprocessable_entity
  end

  private

  def login(user)
    delete logout_path
    post login_path, params: { email: user.email, password: 'password' }
    assert_response :redirect
  end

  def create_shift(started_at: '2026-10-10 09:00:00', ended_at: '2026-10-10 11:00:00')
    ClockShift.create!(user: @user, employee: @worker, employee_key: @worker.id.to_s,
      employee_name: @worker.name, employment_type: @worker.employment_type,
      started_at: Time.zone.parse(started_at), ended_at: Time.zone.parse(ended_at), request_token: SecureRandom.uuid)
  end

  def proposal
    { clock_correction: { proposed_started_at: '2026-10-10T08:00:00', proposed_ended_at: '2026-10-10T10:00:00', reason: 'Missed remote punch' } }
  end
end
