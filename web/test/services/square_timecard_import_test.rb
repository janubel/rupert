# frozen_string_literal: true

require 'test_helper'

class SquareTimecardImportTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
    Current.user = users(:regular_user)
    @worker = People::Employee.create!(first_name: 'Square', last_name: 'Worker')
    @identity = EmployeeSourceIdentity.create!(employee: @worker, source: 'square', external_id: 'native-team-1')
  end
  teardown { Current.reset }

  def card(id = 'native-card-1', **attributes)
    { 'id' => id, 'team_member_id' => @identity.external_id, 'location_id' => 'native-location-1', 'timezone' => 'America/New_York',
      'start_at' => '2026-10-05T09:00:00-04:00', 'end_at' => '2026-10-05T17:00:00-04:00', 'status' => 'CLOSED', 'version' => 1,
      'updated_at' => '2026-10-06T10:00:00Z', 'wage' => { 'hourly_rate' => { 'amount' => 2000, 'currency' => 'USD' } } }.merge(attributes.stringify_keys)
  end

  def import(rows, apply: true)
    SquareTimecardImport.new(rows: rows).call(apply: apply)
  end

  test 'dry run is read only and repeated publications count each native ID once without changing HR or payroll' do
    original = [@worker.attributes, @identity.attributes, User.order(:id).map(&:attributes), EmployeeAccessGrant.count]
    assert_no_difference ['SquareTimecard.count', 'SquareTimecardDay.count', 'ActivityLog.count'] do
      result = import([card], apply: false)
      assert_equal 1, result[:new_timecards]
      assert_equal 28_800, result[:new_paid_seconds]
    end
    first = import([card])
    assert_equal 1, first[:new_timecards]
    assert_equal 28_800, first[:new_paid_seconds]
    assert_equal 1, SquareTimecard.count
    assert_equal 1, SquareTimecardDay.count
    assert_no_difference ['SquareTimecard.count', 'SquareTimecardDay.count'] do
      result = import([card])
      assert_equal 0, result[:new_timecards]
      assert_equal 0, result[:new_paid_seconds]
    end
    assert_equal original, [@worker.reload.attributes, @identity.reload.attributes, User.order(:id).map(&:attributes), EmployeeAccessGrant.count]
    assert_equal 0, People::Timesheet.count
    assert_equal 0, People::PayRate.count
    assert_equal 0, People::Payslip.count
    record = SquareTimecard.first
    assert_equal @worker, record.employee
    assert_equal 'native-card-1', record.external_id
    refute_includes record.source_payload_before_type_cast, 'native-team-1'
    summary = EmployeeWorkSummary.new(employee: @worker, from: Date.new(2026, 10, 5), to: Date.new(2026, 10, 5))
    assert_equal 8, summary.hours
    assert_equal 16_000, summary.gross_cents
    assert_includes summary.csv, 'native-card-1'
    run = People::PayRun.create!(name: 'Do not pay historical hours again', period_start: '2026-10-05', period_end: '2026-10-11')
    @worker.pay_rates.create!(effective_on: '2026-01-01', pay_type: 'hourly', hourly_rate_cents: 9999)
    assert_empty People::PayrollCalculator.generate!(run)
  end

  test 'source timezone overnight DST and unpaid breaks preserve exact time without treating paid breaks as deductions' do
    row = card(start_at: '2026-03-07T23:30:00-05:00', end_at: '2026-03-08T04:30:00-04:00', breaks: [
      { 'start_at' => '2026-03-07T23:45:00-05:00', 'end_at' => '2026-03-08T00:15:00-05:00', 'is_paid' => false },
      { 'start_at' => '2026-03-08T03:00:00-04:00', 'end_at' => '2026-03-08T03:10:00-04:00', 'is_paid' => true }
    ])
    import([row])
    assert_equal 12_600, SquareTimecard.first.payable_seconds
    assert_equal 1800, SquareTimecard.first.unpaid_break_seconds
    assert_equal [[Date.new(2026, 3, 7), 900], [Date.new(2026, 3, 8), 11_700]], SquareTimecardDay.order(:worked_on).pluck(:worked_on, :payable_seconds)
    assert_equal BigDecimal('3.5'), SquareTimecardDay.sum(:payable_seconds) / BigDecimal('3600')
  end

  test 'zero-duration records are retained without hours and open unmatched invalid records do not count' do
    rows = [card('zero', end_at: '2026-10-05T09:00:00-04:00'), card('open', end_at: nil, status: 'OPEN'),
      card('unknown', team_member_id: 'no-matching-identity'), card('bad-zone', timezone: 'invalid-zone'),
      card('bad-break', breaks: [{ 'start_at' => '2026-10-05T10:00:00-04:00', 'end_at' => '2026-10-05T11:00:00-04:00', 'is_paid' => false },
        { 'start_at' => '2026-10-05T10:30:00-04:00', 'end_at' => '2026-10-05T11:30:00-04:00', 'is_paid' => false }]),
      card('negative', end_at: '2026-10-05T08:59:00-04:00')]
    result = import(rows)
    assert_equal({ 'imported' => 1, 'open' => 1, 'unmatched' => 1, 'invalid' => 3 }, result[:statuses])
    assert_equal 0, SquareTimecardDay.count
    assert_equal 0, SquareTimecard.overlapping(@worker.id, Time.iso8601(card['start_at']), Time.iso8601(card['end_at'])).count
    @identity.update!(external_id: 'no-matching-identity')
    result = import([card('unknown', team_member_id: 'no-matching-identity')])
    assert_equal 1, result[:new_timecards]
    assert_equal 1, SquareTimecardDay.count
  end

  test 'source corrections and missing timecards retain original hours without adding or rewriting entries' do
    import([card])
    days = SquareTimecardDay.first.attributes
    original = SquareTimecard.first.source_payload
    result = import([card(end_at: '2026-10-05T18:00:00-04:00', version: 2)])
    assert_equal({ 'changed' => 1 }, result[:statuses])
    assert_equal days, SquareTimecardDay.first.attributes
    assert_equal original, SquareTimecard.first.source_payload
    assert_equal 28_800, SquareTimecard.first.payable_seconds
    import([])
    assert_equal 'missing', SquareTimecard.first.import_status
    assert_equal 28_800, SquareTimecardDay.sum(:payable_seconds)
    result = import([card])
    assert_equal 0, result[:new_timecards]
    assert_equal 'imported', SquareTimecard.first.import_status
    assert_equal 1, SquareTimecardDay.count
  end

  test 'overlapping source cards and ambiguous local manual hours are held rather than doubled' do
    result = import([card('a'), card('b', start_at: '2026-10-05T16:00:00-04:00', end_at: '2026-10-05T18:00:00-04:00')])
    assert_equal({ 'conflict' => 2 }, result[:statuses])
    assert_equal 0, SquareTimecardDay.count
    sheet = @worker.timesheets.create!(period_start: '2026-10-05', period_end: '2026-10-11')
    sheet.entries.create!(worked_on: '2026-10-05', hours: 8)
    result = import([card('manual-overlap')])
    assert_equal({ 'conflict' => 1 }, result[:statuses])
    assert_equal 0, SquareTimecardDay.count
    assert_equal 8, sheet.entries.sum(:hours)
  end

  def open_clock_in(worker, at, token)
    user = User.create!(tenant: Current.tenant, email: "#{token}@example.invalid", password: 'password123', role: 'employee')
    worker.update!(user: user)
    ClockShift.create!(user: user, employee: worker, employee_key: worker.id.to_s, employee_name: worker.name,
      employment_type: 'part_time', request_token: token, started_at: Time.zone.parse(at))
  end

  test 'a clock-in left open for days does not hold every later Square card, but a fresh one still does' do
    open_clock_in(@worker, '2026-10-03 09:00', 'stale_open_token_123')
    result = import([card])
    assert_equal({ 'imported' => 1 }, result[:statuses], 'clock-in 2 days earlier was a missed clock-out')
    assert_equal 28_800, SquareTimecardDay.sum(:payable_seconds)

    other = People::Employee.create!(first_name: 'Fresh', last_name: 'Open')
    EmployeeSourceIdentity.create!(employee: other, source: 'square', external_id: 'native-team-2')
    open_clock_in(other, '2026-10-05 08:00', 'fresh_open_token_456')
    result = import([card('fresh-overlap', team_member_id: 'native-team-2')])
    assert_equal({ 'conflict' => 1 }, result[:statuses], 'a clock-in an hour earlier still overlaps')
  end

  test 'new source IDs overlapping imported history are held and later local entry creation is guarded' do
    import([card])
    result = import([card, card('duplicate-native-interval')])
    assert_equal({ 'imported' => 1, 'conflict' => 1 }, result[:statuses])
    assert_equal 28_800, SquareTimecardDay.sum(:payable_seconds)
    sheet = @worker.timesheets.create!(period_start: '2026-10-05', period_end: '2026-10-11')
    assert_raises(ActiveRecord::RecordInvalid) { sheet.entries.create!(worked_on: '2026-10-05', hours: 8) }
    assert_raises(ActiveRecord::RecordInvalid) { sheet.entries.create!(worked_on: '2026-10-05', hours: 1, work_type: 'overtime') }
    sheet.entries.create!(worked_on: '2026-10-06', hours: 8)
    assert_equal 8, sheet.entries.sum(:hours)
  end

  test 'inactive historical employees can match without activation invitations or login grants' do
    @worker.terminate!
    before = @worker.attributes
    import([card])
    assert_equal 28_800, SquareTimecardDay.sum(:payable_seconds)
    assert_equal before, @worker.reload.attributes
    assert_nil @worker.user_id
    assert_equal 0, EmployeeAccessGrant.count
  end

  test 'duplicate source IDs roll back the whole publication and unauthorized tenants cannot import' do
    assert_no_difference ['SquareTimecard.count', 'SquareTimecardDay.count'] do
      assert_raises(SquareTimecardImport::Error) { import([card, card]) }
    end
    Current.user = User.create!(tenant: Current.tenant, email: 'square-employee@example.invalid', password: 'password123', role: 'employee')
    assert_raises(Pundit::NotAuthorizedError) { import([card]) }
    Current.user = users(:regular_user)
    Current.tenant = Tenant.create!(name: 'Other tenant', subdomain: 'other-square-import')
    assert_raises(Pundit::NotAuthorizedError) { import([card]) }
  end
end
