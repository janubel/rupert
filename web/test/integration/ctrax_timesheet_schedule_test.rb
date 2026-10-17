# frozen_string_literal: true

require 'test_helper'

class CtraxTimesheetScheduleTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    Current.user = users(:regular_user)
    @admin = Current.user
    @connection = PosConnection.create!(provider: 'ctrax', vendor_approved: true,
      credentials_json: { api_url: 'https://fixture.api.cannatrax.net', api_username: 'fixture', api_password: 'secret' }.to_json)
  end

  teardown { Current.reset }

  def sign_in(user = @admin, password: 'password')
    post login_path, params: { email: user.email, password: password }
    Current.tenant = @tenant
  end

  test 'authorized administrator can enable and disable without a source read or immediate job' do
    Ctrax::LaborImport.expects(:call).never
    sign_in
    get people_ctrax_timesheets_path
    assert_response :success
    assert_select 'form[action=?]', people_ctrax_timesheet_schedule_path
    assert_includes response.body, 'No successful read recorded'
    assert_no_enqueued_jobs do
      patch people_ctrax_timesheet_schedule_path, params: { enabled: '1' }
    end
    assert_redirected_to people_ctrax_timesheets_path
    Current.tenant = @tenant
    first = CtraxLaborSync.configuration
    assert_equal true, first['enabled']
    assert_equal @admin.id, first['actor_id']
    assert first['version'].present?
    get people_ctrax_timesheets_path
    assert_response :success
    assert_equal 'no-store', response.headers['Cache-Control']
    assert_includes response.body, 'Next scheduled slot (estimate)'
    assert_includes response.body, ':02, :17, :32 and :47'
    patch people_ctrax_timesheet_schedule_path, params: { enabled: '0' }
    assert_redirected_to people_ctrax_timesheets_path
    Current.tenant = @tenant
    assert_equal false, CtraxLaborSync.configuration['enabled']
    refute_equal first['version'], CtraxLaborSync.configuration['version']
    assert_equal 2, ActivityLog.where(action: 'ctrax_labor_schedule_updated').count
  end

  test 'reviewers can inspect refresh status but cannot configure and employees have no controls' do
    %w[manager shift_leader employee].each do |role|
      user = User.create!(tenant: @tenant, email: "schedule-#{role}@example.invalid", password: 'password123', role: role)
      People::Employee.create!(first_name: 'Own', last_name: role, user: user)
      sign_in(user, password: 'password123')
      get people_ctrax_timesheets_path
      assert_response :success
      assert_select 'form[action=?]', people_ctrax_timesheet_schedule_path, count: 0
      assert_select '[aria-label="Automatic C-Trax timecard refresh"]', count: role == 'employee' ? 0 : 1
      assert_no_difference ['Setting.count', 'ActivityLog.count'] do
        patch people_ctrax_timesheet_schedule_path, params: { enabled: '1' }
      end
      assert_response :redirect
    end
  end

  test 'invalid input and incomplete connection retain the existing schedule' do
    sign_in
    assert_no_difference ['Setting.count', 'ActivityLog.count'] do
      patch people_ctrax_timesheet_schedule_path, params: { enabled: 'yes' }
    end
    assert_response :unprocessable_entity
    @connection.update_columns(vendor_approved: false)
    patch people_ctrax_timesheet_schedule_path, params: { enabled: '1' }
    assert_redirected_to people_ctrax_timesheets_path
    assert flash[:alert].present?
    Current.tenant = @tenant
    refute CtraxLaborSync.enabled?
  end

  test 'successful and failed attempts display safe local status without foreign workspace metadata' do
    SyncAttempt.create!(source: 'ctrax', operation: 'timecards', status: 'succeeded', queued_at: 20.minutes.ago,
      started_at: 19.minutes.ago, finished_at: 18.minutes.ago)
    SyncAttempt.create!(source: 'ctrax', operation: 'timecards', status: 'failed', queued_at: 3.minutes.ago,
      started_at: 2.minutes.ago, finished_at: 1.minute.ago, error_category: 'access')
    other = Tenant.create!(name: 'Private schedule tenant', subdomain: 'private-schedule')
    SyncAttempt.unscoped.create!(tenant: other, source: 'ctrax', operation: 'timecards', status: 'failed',
      queued_at: Time.current, finished_at: Time.current, error_category: 'encryption')
    sign_in
    get people_ctrax_timesheets_path
    assert_response :success
    assert_includes response.body, 'Last successful recorded read:'
    refute_includes response.body, 'No successful read recorded'
    assert_includes response.body, 'Failed'
    assert_includes response.body, 'Vendor access denied'
    assert_includes response.body, 'Previous source history is retained'
    refute_includes response.body, 'Saved credentials unreadable'
    refute_includes response.body, 'api_password'
    refute_includes response.body, 'fixture.api.cannatrax.net'
  end

  test 'revoked authorizer and lost administration permission cannot silently re-enable' do
    CtraxLaborSync.configure!(enabled: true)
    viewer = User.create!(tenant: @tenant, email: 'schedule-viewer@example.invalid', password: 'password123', role: 'manager')
    @admin.update_permission_overrides!(%w[dashboard.read timesheets.read timesheets.write])
    sign_in(viewer, password: 'password123')
    get people_ctrax_timesheets_path
    assert_response :success
    assert_includes response.body, 'Administrator review required'
    sign_in
    Current.tenant = @tenant
    before = CtraxLaborSync.configuration
    patch people_ctrax_timesheet_schedule_path, params: { enabled: '1' }
    assert_response :redirect
    Current.tenant = @tenant
    assert_equal before, CtraxLaborSync.configuration
    assert_no_difference 'CtraxLaborShift.count' do
      get people_ctrax_timesheets_path
    end
    assert_select 'form[action=?]', people_ctrax_timesheet_schedule_path, count: 0
  end

  test 'schedule writes are bound to signed in workspace and disabled accounts are denied' do
    other = Tenant.create!(name: 'Other C-Trax schedule', subdomain: 'other-ctrax-schedule')
    sign_in
    patch people_ctrax_timesheet_schedule_path, params: { enabled: '1', tenant_id: other.id, actor_id: 999_999 }
    assert_redirected_to people_ctrax_timesheets_path
    Current.tenant = @tenant
    assert CtraxLaborSync.enabled?
    assert_equal @admin.id, CtraxLaborSync.configuration['actor_id']
    assert_nil Setting.unscoped.find_by(tenant_id: other.id, key: CtraxLaborSync::KEY)
    @admin.update!(active: false)
    before = CtraxLaborSync.configuration
    patch people_ctrax_timesheet_schedule_path, params: { enabled: '0' }
    assert_redirected_to login_path
    Current.tenant = @tenant
    assert_equal before, CtraxLaborSync.configuration
  end
end
