# frozen_string_literal: true

require 'test_helper'

class EmployeeConsolidationTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
    @primary = profile('ctrax', '1')
    @duplicate = profile('square', 'team-1')
  end
  teardown { Current.reset }

  def profile(source, external_id)
    employee = People::Employee.create!(first_name: 'Alex', last_name: 'Worker', email: 'alex@example.com',
      employment_type: 'unspecified', source: source, external_id: external_id, source_active: true)
    employee.source_identities.create!(source: source, external_id: external_id, first_name: employee.first_name,
      last_name: employee.last_name, email: employee.email, source_active: true)
    employee
  end

  def merge
    EmployeeConsolidation.call(primary_id: @primary.id, duplicate_ids: [@duplicate.id], reason: 'Owner confirmed same person')
  end

  test 'consolidation retains every native identity and original profile while moving time history and revoking access' do
    user = User.create!(tenant: Current.tenant, email: 'alex@example.com', password: 'password123', role: 'employee')
    @primary.update!(email: 'preferred@example.com')
    @duplicate.update!(user: user, employee_number: 'EXISTING-123')
    secret = EmployeeAccessGrant.issue!(@duplicate)
    session, = EmployeeAppSession.issue!(user: user, device_name: 'Test')
    shift = ClockShift.create!(user: user, employee: @duplicate, employee_key: @duplicate.id.to_s,
      employee_name: @duplicate.name, employment_type: 'unspecified', started_at: 3.hours.ago, ended_at: 2.hours.ago, request_token: 'a' * 32)
    sheet = People::Timesheet.create!(employee: @duplicate, period_start: Date.current.beginning_of_week, period_end: Date.current.end_of_week)
    entry = sheet.entries.create!(worked_on: Date.current, hours: 2, work_type: 'regular')
    report = @duplicate.work_reports.create!(requester: user, kind: 'time', details: 'Check recorded hours', request_key: SecureRandom.uuid)
    balance = @duplicate.leave_balances.create!(leave_type: 'vacation', year: Date.current.year, accrued_hours: 8)
    assert_difference 'People::Employee.count', -1 do
      assert_no_difference ['People::Employee.unscoped.count', 'EmployeeSourceIdentity.count', 'People::Timesheet.count'] do
        merge
      end
    end
    assert_equal user.id, @primary.reload.user_id
    assert_equal @primary.id, sheet.reload.employee_id
    assert_equal sheet.id, entry.reload.timesheet_id
    assert_equal @primary.id, balance.reload.employee_id
    assert_equal @primary.id, report.reload.employee_id
    assert_equal [@primary.id, @primary.id.to_s], shift.reload.attributes.values_at('employee_id', 'employee_key')
    assert_equal %w[ctrax square], @primary.source_identities.order(:source).pluck(:source)
    original = People::Employee.unscoped.find(@duplicate.id)
    assert_equal @primary.id, original.merged_into_id
    assert_nil original.user_id
    assert_equal 'EXISTING-123', @primary.employee_number
    assert_equal 'EXISTING-123', JSON.parse(original.merge_snapshot).fetch('employee_number')
    assert_equal user.id, JSON.parse(original.merge_snapshot).fetch('user_id')
    refute EmployeeAccessGrant.lookup(secret).usable?
    refute session.reload.usable?
    assert ActivityLog.find_by!(action: 'employee_profiles_consolidated').details.include?(@duplicate.id.to_s)
    @primary.terminate!
    assert_not @primary.destroy
    assert People::Employee.unscoped.exists?(@duplicate.id)
  end

  test 'directory refresh resolves merged source identities and keeps curated HR contact details' do
    merge
    @primary.update!(first_name: 'Preferred', email: 'preferred@example.com')
    EnvStore.set('SQUARE_ACCESS_TOKEN', 'fixture')
    EnvStore.set('SQUARE_ENVIRONMENT', 'production')
    stub_request(:post, 'https://connect.squareup.com/v2/team-members/search')
      .to_return(status: 200, headers: { 'Content-Type' => 'application/json' },
        body: { team_members: [{ id: 'team-1', status: 'ACTIVE', given_name: 'Native', family_name: 'Worker', email_address: 'native@example.com' }] }.to_json)
    assert_no_difference ['People::Employee.count', 'EmployeeSourceIdentity.count'] do
      2.times { assert_equal 1, Directories::Sync.call(provider: 'square', kind: 'employees') }
    end
    assert_equal ['Preferred', 'preferred@example.com'], @primary.reload.attributes.values_at('first_name', 'email')
    assert_equal 'native@example.com', @primary.source_identities.find_by!(source: 'square').email
  end

  test 'shared email does not silently merge a newly discovered source account' do
    EnvStore.set('SQUARE_ACCESS_TOKEN', 'fixture')
    EnvStore.set('SQUARE_ENVIRONMENT', 'production')
    stub_request(:post, 'https://connect.squareup.com/v2/team-members/search')
      .to_return(status: 200, headers: { 'Content-Type' => 'application/json' },
        body: { team_members: [{ id: 'new', status: 'ACTIVE', given_name: 'Different', family_name: 'Person', email_address: 'alex@example.com' }] }.to_json)
    assert_difference 'People::Employee.count', 1 do
      Directories::Sync.call(provider: 'square', kind: 'employees')
    end
  end

  test 'cross tenant and conflicting accounts cannot consolidate' do
    foreign = Tenant.create!(name: 'Other', subdomain: 'consolidation-other')
    outsider = People::Employee.unscoped.create!(tenant: foreign, first_name: 'Alex', last_name: 'Worker')
    assert_raises(ActiveRecord::RecordNotFound) { EmployeeConsolidation.call(primary_id: @primary.id, duplicate_ids: [outsider.id], reason: 'Confirmed') }
    @primary.update!(user: users(:regular_user))
    @duplicate.update!(user: User.create!(tenant: Current.tenant, email: 'different@example.com', password: 'password123'))
    assert_raises(EmployeeConsolidation::Error) { merge }
    assert_nil @duplicate.reload.merged_into_id
  end

  test 'overlapping time and duplicate leave cannot be combined or lost' do
    [@primary, @duplicate].each do |employee|
      People::Timesheet.create!(employee: employee, period_start: '2026-10-05', period_end: '2026-10-11')
    end
    assert_no_difference ['People::Employee.count', 'People::Timesheet.count'] do
      assert_raises(EmployeeConsolidation::Error) { merge }
    end
    People::Timesheet.where(employee_id: @duplicate.id).delete_all
    [@primary, @duplicate].each { |employee| employee.leave_balances.create!(leave_type: 'vacation', year: 2026, accrued_hours: 10) }
    assert_raises(EmployeeConsolidation::Error) { merge }
    assert_equal 2, People::LeaveBalance.where(employee_id: [@primary.id, @duplicate.id]).count
  end

  test 'new setup links require an individual active identity and preserve privileged accounts' do
    assert_raises(TimesheetWorkflow::Error) { EmployeeAccessGrant.issue!(@primary) }
    merge
    @primary.source_identities.update_all(source_active: false)
    assert_raises(TimesheetWorkflow::Error) { EmployeeAccessGrant.issue!(@primary) }
    @primary.source_identities.first.update!(source_active: true)
    admin = User.create!(tenant: Current.tenant, email: @primary.email, password: 'password123', role: 'admin')
    assert_raises(TimesheetWorkflow::Error) { EmployeeAccessGrant.issue!(@primary) }
    @primary.update!(user: admin)
    assert_raises(TimesheetWorkflow::Error) { EmployeeAccessGrant.issue!(@primary) }
    assert admin.reload.admin?
  end
end
