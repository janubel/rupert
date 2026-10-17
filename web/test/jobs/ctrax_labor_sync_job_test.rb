# frozen_string_literal: true

require 'test_helper'

class CtraxLaborSyncJobTest < ActiveJob::TestCase
  setup do
    Current.user = users(:regular_user)
    @admin = Current.user
    @tenant = Current.tenant
    @origin = 'https://schedule.api.cannatrax.net'
    @connection = PosConnection.create!(provider: 'ctrax', vendor_approved: true,
      credentials_json: { api_url: @origin, api_username: 'synthetic', api_password: 'PRIVATE-PASSWORD' }.to_json)
    @worker = People::Employee.create!(first_name: 'Scheduled', last_name: 'Worker')
    EmployeeSourceIdentity.create!(employee: @worker, source: 'ctrax', external_id: 'schedule.api.cannatrax.net/22')
    stub_request(:post, "#{@origin}/api/auth/login").to_return(json(token: 'PRIVATE-TOKEN', permissions: { accessible_stores: { '7' => 'Synthetic' } }))
    stub_rows([row])
  end
  teardown { Current.reset }

  def row
    { 'id' => 1, 'store_id' => 7, 'user_id' => 22, 'user' => { 'id' => 22 },
      'started_at' => '2026-10-05T09:00:00Z', 'ended_at' => '2026-10-05T17:00:00Z',
      'number_of_hours' => 8.0, 'is_in_progress' => false, 'is_verified' => true,
      'deleted_at' => nil, 'updated_at' => '2026-10-06T00:00:00Z' }
  end

  def json(value)
    { status: 200, headers: { 'Content-Type' => 'application/json' }, body: value.to_json }
  end

  def page(rows)
    json(data: rows, current_page: 1, last_page: 1, total: rows.length)
  end

  def stub_rows(closed)
    stub_request(:get, "#{@origin}/api/v1/laborShifts").with(query: { is_in_progress: '0', page: '1', per_page: '50' }).to_return(page(closed))
    stub_request(:get, "#{@origin}/api/v1/laborShifts").with(query: { is_in_progress: '1', page: '1', per_page: '50' }).to_return(page([]))
  end

  def enable
    CtraxLaborSync.configure!(enabled: true)
  end

  test 'explicit tenant opt in queues only tenant IDs and static diagnostics at the offset cadence' do
    assert_no_enqueued_jobs { CtraxLaborSyncJob.perform_now }
    enable
    assert_enqueued_with(job: CtraxLaborSyncJob, args: [@tenant.id]) { CtraxLaborSyncJob.perform_now }
    attempt = SyncAttempt.find_by!(source: 'ctrax', operation: 'timecards', status: 'queued')
    assert_equal @tenant.id, attempt.tenant_id
    refute_includes enqueued_jobs.to_json, 'PRIVATE'
    other = Tenant.create!(name: 'Unconfigured', subdomain: 'unconfigured-ctrax-time')
    Ctrax::Client.expects(:new).never
    CtraxLaborSyncJob.perform_now(other.id)
    CtraxLaborSync.configure!(enabled: false)
    assert_no_enqueued_jobs { CtraxLaborSyncJob.perform_now }
    config = YAML.load_file(Rails.root.join('config/recurring.yml'))
    assert_equal '2,17,32,47 * * * *', config.dig('production', 'ctrax_timecards', 'schedule')
    assert_equal 'CtraxLaborSyncJob', config.dig('production', 'ctrax_timecards', 'class')
  end

  test 'repeated automatic reads preserve all historical evidence without HR payroll or canonical time writes' do
    enable
    original = [@worker.attributes, @admin.attributes, EmployeeAccessGrant.count, People::TimesheetEntry.count, ClockShift.count, People::Payslip.count]
    2.times { CtraxLaborSyncJob.perform_now(@tenant.id) }
    assert_equal 1, CtraxLaborShift.count
    assert_equal 1, CtraxLaborObservation.count
    assert_equal 2, SyncAttempt.where(source: 'ctrax', operation: 'timecards', status: 'succeeded').count
    assert_equal original, [@worker.reload.attributes, @admin.reload.attributes, EmployeeAccessGrant.count, People::TimesheetEntry.count, ClockShift.count, People::Payslip.count]
    refute_includes SyncAttempt.all.map(&:attributes).to_json, 'PRIVATE'
    refute_includes Setting.find_by!(key: CtraxLaborSync::KEY).value_before_type_cast, 'actor_id'
    assert_not_requested :post, %r{/api/v1/}
  end

  test 'disabled revoked and suspended authorizations never start a vendor read' do
    enable
    Ctrax::Client.expects(:new).never
    @admin.update!(active: false)
    assert_raises(Ctrax::LaborImport::Error) { CtraxLaborSyncJob.perform_now(@tenant.id) }
    assert_equal 'setup_changed', SyncAttempt.where(source: 'ctrax', operation: 'timecards').last.error_category
    @tenant.update!(status: 'suspended')
    CtraxLaborSyncJob.perform_now(@tenant.id)
    @tenant.update!(status: 'active')
    @admin.update!(active: true)
    CtraxLaborSync.configure!(enabled: false)
    CtraxLaborSyncJob.perform_now(@tenant.id)
  end

  test 'store admins and platform admins can configure but employee and foreign ordinary admins cannot' do
    employee = User.create!(tenant: @tenant, role: 'employee', email: 'ctrax-sync-employee@example.invalid', password: 'password123')
    assert_raises(Pundit::NotAuthorizedError) { CtraxLaborSync.configure!(enabled: true, actor: employee) }
    other = Tenant.create!(name: 'Other schedule', subdomain: 'ctrax-other-schedule')
    foreign = User.create!(tenant: other, role: 'admin', email: 'ctrax-sync-other@example.invalid', password: 'password123')
    assert_raises(Pundit::NotAuthorizedError) { CtraxLaborSync.configure!(enabled: true, actor: foreign) }
    foreign.update!(role: 'super_admin')
    CtraxLaborSync.configure!(enabled: true, actor: foreign)
    assert_equal foreign.id, CtraxLaborSync.configuration['actor_id']
    assert_raises(Ctrax::LaborImport::Error) { CtraxLaborSync.configure!(enabled: '1') }
    @connection.update!(vendor_approved: false, credentials_json: nil)
    assert_raises(Ctrax::LaborImport::Error) { CtraxLaborSync.configure!(enabled: true) }
    CtraxLaborSync.configure!(enabled: false)
    refute CtraxLaborSync.enabled?
  end

  test 'disabling or refreshing approval during an in flight read prevents every publication' do
    enable
    stub_request(:get, "#{@origin}/api/v1/laborShifts").with(query: { is_in_progress: '1', page: '1', per_page: '50' }).to_return do
      CtraxLaborSync.configure!(enabled: false, actor: @admin)
      page([])
    end
    assert_raises(Ctrax::LaborImport::Error) { CtraxLaborSyncJob.perform_now(@tenant.id) }
    assert_equal 0, CtraxLaborShift.count
    assert_equal 0, CtraxLaborObservation.count
    refute CtraxLaborSync.enabled?
    enable
    before = CtraxLaborSync.configuration['version']
    stub_request(:get, "#{@origin}/api/v1/laborShifts").with(query: { is_in_progress: '1', page: '1', per_page: '50' }).to_return do
      CtraxLaborSync.configure!(enabled: true, actor: @admin)
      page([])
    end
    assert_raises(Ctrax::LaborImport::Error) { CtraxLaborSyncJob.perform_now(@tenant.id) }
    refute_equal before, CtraxLaborSync.configuration['version']
    assert_equal 0, CtraxLaborShift.count
  end

  test 'revocation during source acquisition rejects publication and keeps existing encrypted evidence' do
    enable
    CtraxLaborSyncJob.perform_now(@tenant.id)
    before = [CtraxLaborShift.first.attributes, CtraxLaborObservation.first.attributes]
    stub_request(:get, "#{@origin}/api/v1/laborShifts").with(query: { is_in_progress: '1', page: '1', per_page: '50' }).to_return do
      @admin.update_permission_overrides!(%w[users.write timesheets.read])
      page([])
    end
    assert_raises(Pundit::NotAuthorizedError) { CtraxLaborSyncJob.perform_now(@tenant.id) }
    assert_equal before, [CtraxLaborShift.first.attributes, CtraxLaborObservation.first.attributes]
  end

  test 'partial failure and recovery have independent safe timecard health and preserve previous history' do
    enable
    CtraxLaborSyncJob.perform_now(@tenant.id)
    before = [CtraxLaborShift.first.attributes, CtraxLaborObservation.first.attributes]
    stub_request(:get, "#{@origin}/api/v1/laborShifts").with(query: { is_in_progress: '1', page: '1', per_page: '50' }).to_return(status: 403)
    assert_raises(Ctrax::LaborImport::Error) { CtraxLaborSyncJob.perform_now(@tenant.id) }
    assert_equal before, [CtraxLaborShift.first.attributes, CtraxLaborObservation.first.attributes]
    health = SourceHealth.for(key: 'ctrax', ready: true).find { |channel| channel[:operation] == 'timecards' }
    assert_equal 'Failed', health[:state]
    assert_equal 'entitlement', health[:category]
    assert health[:enabled]
    assert health[:last_success_at]
    assert_nil health[:source_event_at]
    assert_nil health[:source_at]
    assert_includes health[:coverage], 'separate from Rupert time and payroll'
    stub_rows([row])
    CtraxLaborSyncJob.perform_now(@tenant.id)
    assert_equal 'succeeded', SyncAttempt.where(source: 'ctrax', operation: 'timecards').last.status
    CtraxLaborSync.configure!(enabled: false)
    refute SourceHealth.for(key: 'ctrax', ready: true).find { |channel| channel[:operation] == 'timecards' }[:enabled]
  end
end
