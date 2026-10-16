# frozen_string_literal: true

require 'test_helper'

class SquareTimecardSyncJobTest < ActiveJob::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
    Current.user = users(:regular_user)
    @admin = Current.user
    @tenant = Current.tenant
    @worker = People::Employee.create!(first_name: 'Synced', last_name: 'Worker')
    EmployeeSourceIdentity.create!(employee: @worker, source: 'square', external_id: 'sync-team')
    SquareClient.stubs(:configured?).returns(true)
    SquareClient.stubs(:token).returns('synthetic-private-token')
    SquareClient.stubs(:environment).returns('production')
  end
  teardown { Current.reset }

  def row(status = 'CLOSED')
    { 'id' => 'sync-card', 'team_member_id' => 'sync-team', 'location_id' => 'sync-location', 'timezone' => 'America/New_York',
      'start_at' => '2026-10-05T09:00:00-04:00', 'end_at' => status == 'CLOSED' ? '2026-10-05T17:00:00-04:00' : nil, 'status' => status }
  end

  def enable
    SquareTimecardSync.configure!(enabled: true)
  end

  test 'schedule opts in each tenant explicitly and queues only tenant IDs with safe diagnostics' do
    assert_no_enqueued_jobs { SquareTimecardSyncJob.perform_now }
    enable
    job = nil
    assert_enqueued_with(job: SquareTimecardSyncJob, args: [@tenant.id]) { SquareTimecardSyncJob.perform_now }
    job = enqueued_jobs.find { |queued| queued[:job] == SquareTimecardSyncJob }
    refute_includes job.inspect, 'synthetic-private-token'
    assert_equal 'queued', SyncAttempt.where(source: 'square', operation: 'timecards').last.status
    other = Tenant.create!(name: 'Unconfigured', subdomain: 'unconfigured-timecards')
    SquareClient.expects(:request).never
    SquareTimecardSyncJob.perform_now(other.id)
    SquareTimecardSync.configure!(enabled: false)
    assert_no_enqueued_jobs { SquareTimecardSyncJob.perform_now }
  end

  test 'closed shifts sync repeatedly once while open shifts wait and HR payroll and grants are preserved' do
    enable
    before = [@worker.attributes, @admin.attributes, EmployeeAccessGrant.count, People::Timesheet.count, People::Payslip.count]
    SquareClient.expects(:request).with('/labor/timecards/search', method: 'POST', body: { limit: 200, query: { sort: { field: 'START_AT', order: 'ASC' } } }).returns({ 'timecards' => [row('OPEN')] })
    SquareTimecardSyncJob.perform_now(@tenant.id)
    assert_equal 'open', SquareTimecard.first.import_status
    assert_equal 0, SquareTimecardDay.sum(:payable_seconds)
    SquareClient.stubs(:request).returns({ 'timecards' => [row] })
    2.times { SquareTimecardSyncJob.perform_now(@tenant.id) }
    assert_equal 1, SquareTimecard.count
    assert_equal 1, SquareTimecardDay.count
    assert_equal 28_800, SquareTimecardDay.sum(:payable_seconds)
    assert_equal 3, SyncAttempt.where(source: 'square', operation: 'timecards', status: 'succeeded').count
    assert_equal before, [@worker.reload.attributes, @admin.reload.attributes, EmployeeAccessGrant.count, People::Timesheet.count, People::Payslip.count]
    refute_includes SyncAttempt.all.map(&:attributes).to_json, 'synthetic-private-token'
  end

  test 'partial reads preserve history and record a failed attempt before the next successful refresh' do
    enable
    SquareClient.stubs(:request).returns({ 'timecards' => [row] })
    SquareTimecardSyncJob.perform_now(@tenant.id)
    before = [SquareTimecard.first.attributes, SquareTimecardDay.first.attributes]
    SquareClient.stubs(:request).returns({ 'timecards' => [row], 'cursor' => 'second-page' }, { 'errors' => [{ 'code' => 'ACCESS_DENIED' }] })
    assert_raises(SquareTimecardReader::Error) { SquareTimecardSyncJob.perform_now(@tenant.id) }
    assert_equal before, [SquareTimecard.first.attributes, SquareTimecardDay.first.attributes]
    assert_equal 'failed', SyncAttempt.last.status
    SquareClient.stubs(:request).returns({ 'timecards' => [row] })
    SquareTimecardSyncJob.perform_now(@tenant.id)
    assert_equal 'succeeded', SyncAttempt.last.status
    assert_equal 28_800, SquareTimecardDay.sum(:payable_seconds)
  end

  test 'revoked authorizing accounts and inactive tenants never read and employee accounts cannot enable schedules' do
    enable
    SquareClient.expects(:request).never
    @admin.update!(active: false)
    assert_raises(SquareTimecardImport::Error) { SquareTimecardSyncJob.perform_now(@tenant.id) }
    @tenant.update!(status: 'suspended')
    SquareTimecardSyncJob.perform_now(@tenant.id)
    @tenant.update!(status: 'active')
    employee = User.create!(tenant: @tenant, role: 'employee', email: 'sync-no-escalation@example.invalid', password: 'password123')
    assert_raises(Pundit::NotAuthorizedError) { SquareTimecardSync.configure!(enabled: true, actor: employee) }
    other = Tenant.create!(name: 'Other', subdomain: 'other-sync-actor')
    employee.update!(tenant: other, role: 'admin')
    assert_raises(Pundit::NotAuthorizedError) { SquareTimecardSync.configure!(enabled: true, actor: employee) }
  end

  test 'disabling or changing authorization during a read prevents publication' do
    enable
    reader = mock
    reader.expects(:call).returns([row])
    reader.expects(:verify_connection!).once.with do
      SquareTimecardSync.configure!(enabled: false, actor: @admin)
      true
    end
    SquareTimecardReader.stubs(:new).returns(reader)
    assert_raises(SquareTimecardImport::Error) { SquareTimecardSyncJob.perform_now(@tenant.id) }
    assert_equal 0, SquareTimecard.count
    refute SquareTimecardSync.enabled?
  end

  test 'an older complete read cannot mark a newer publication missing' do
    enable
    reader = mock
    reader.expects(:verify_connection!).twice
    # Publish another complete read after this read started, before it obtains
    # the tenant writer lock. Its new card must not become missing.
    SquareTimecardReader.stubs(:new).returns(reader)
    reader.expects(:call).returns([]).with do
      SquareTimecardImport.new(actor: @admin, rows: [row]).call(apply: true)
      true
    end
    assert_raises(SquareTimecardImport::Error) { SquareTimecardSyncJob.perform_now(@tenant.id) }
    assert_equal 'imported', SquareTimecard.first.import_status
    assert_equal 28_800, SquareTimecardDay.sum(:payable_seconds)
  end

  test 'employee-hours health is independent of catalog success and respects the tenant schedule' do
    enable
    SyncAttempt.create!(source: 'square', operation: 'catalog', status: 'succeeded', queued_at: 1.minute.ago, finished_at: Time.current)
    SyncAttempt.create!(source: 'square', operation: 'timecards', status: 'failed', queued_at: Time.current, finished_at: Time.current, error_category: 'unknown')
    health = SourceHealth.for(key: 'square', ready: true).find { |channel| channel[:operation] == 'timecards' }
    assert_equal 'Failed', health[:state]
    assert health[:enabled]
    assert_nil health[:last_success_at]
    assert_includes health[:coverage], 'Closed matched shifts count once'
    SquareTimecardSync.configure!(enabled: false)
    refute SourceHealth.for(key: 'square', ready: true).find { |channel| channel[:operation] == 'timecards' }[:enabled]
  end
end
