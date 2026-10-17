# frozen_string_literal: true

require 'test_helper'

class CtraxEmployeeConsolidationTest < ActionDispatch::IntegrationTest
  test 'consolidation preserves C-Trax source history for primary employee and stable reread' do
    tenant = tenants(:default_tenant)
    Current.tenant = tenant
    Current.user = users(:regular_user)
    employee_user = User.create!(tenant: tenant, email: 'ctrax-consolidated@example.invalid', password: 'password123', role: 'employee')
    primary = People::Employee.create!(first_name: 'Primary', last_name: 'Worker', user: employee_user)
    duplicate = People::Employee.create!(first_name: 'Native', last_name: 'Profile')
    EmployeeSourceIdentity.create!(employee: duplicate, source: 'ctrax', external_id: 'fixture.api.cannatrax.net/22')
    origin = 'https://fixture.api.cannatrax.net'
    PosConnection.create!(provider: 'ctrax', vendor_approved: true,
      credentials_json: { api_url: origin, api_username: 'fixture', api_password: 'secret' }.to_json)
    row = { 'id' => 1, 'store_id' => 7, 'user_id' => 22, 'user' => { 'id' => 22 },
      'started_at' => '2026-10-05T09:00:00Z', 'ended_at' => '2026-10-05T17:00:00Z', 'number_of_hours' => 8.0,
      'is_in_progress' => false, 'is_verified' => true, 'deleted_at' => nil, 'updated_at' => '2026-10-06T00:00:00Z' }
    stub_request(:post, "#{origin}/api/auth/login").to_return(json(token: 'ephemeral', permissions: { accessible_stores: { '7' => 'Fixture' } }))
    [false, true].each do |open|
      rows = open ? [] : [row]
      stub_request(:get, "#{origin}/api/v1/laborShifts").with(query: { is_in_progress: open ? '1' : '0', page: '1', per_page: '50' })
        .to_return(json(data: rows, current_page: 1, last_page: 1, total: rows.length))
    end
    Ctrax::LaborImport.call
    shift = CtraxLaborShift.first
    original = shift.attributes.slice('source_payload', 'original_digest', 'external_id', 'started_at', 'ended_at', 'reported_hours')
    assert_equal duplicate.id, shift.employee_id
    EmployeeConsolidation.call(primary_id: primary.id, duplicate_ids: [duplicate.id], reason: 'Confirmed native identity belongs to the primary employee')
    assert_equal primary.id, shift.reload.employee_id
    assert_equal primary.id, EmployeeSourceIdentity.find_by!(source: 'ctrax').employee_id
    assert_equal original, shift.attributes.slice(*original.keys)
    assert_no_difference ['CtraxLaborShift.count', 'People::Timesheet.count', 'People::Payslip.count'] do
      assert_equal 1, Ctrax::LaborImport.call[:imported]
    end
    assert_equal primary.id, shift.reload.employee_id
    assert_equal 'imported', shift.status
    post login_path, params: { email: employee_user.email, password: 'password123' }
    get people_ctrax_timesheets_path
    assert_response :success
    assert_select 'a[href=?]', people_ctrax_timesheet_path(shift)
    get people_ctrax_timesheet_path(shift)
    assert_response :success
    assert_includes response.body, 'Primary Worker'
    Current.tenant = tenant
    detached = People::Employee.create!(first_name: 'Retain', last_name: 'History')
    retained = CtraxLaborShift.create!(shift.attributes.except('id', 'created_at', 'updated_at').merge(employee: detached, external_id: 'retained-source'))
    assert_raises(ActiveRecord::DeleteRestrictionError) { detached.destroy! }
    assert CtraxLaborShift.exists?(retained.id)
  ensure
    Current.reset
  end

  def json(value)
    { status: 200, headers: { 'Content-Type' => 'application/json' }, body: value.to_json }
  end
end
