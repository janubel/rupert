# frozen_string_literal: true

require 'test_helper'

class CtraxLaborImportTest < ActiveSupport::TestCase
  setup do
    Current.user = users(:regular_user)
    @origin = 'https://fixture.api.cannatrax.net'
    @connection = PosConnection.create!(provider: 'ctrax', vendor_approved: true,
      credentials_json: { api_url: @origin, api_username: 'fixture', api_password: 'secret' }.to_json)
    @employee = People::Employee.create!(first_name: 'Source', last_name: 'Worker')
    EmployeeSourceIdentity.create!(employee: @employee, source: 'ctrax', external_id: 'fixture.api.cannatrax.net/22')
    stub_request(:post,
      "#{@origin}/api/auth/login").to_return(json(token: 'ephemeral',
        permissions: { accessible_stores: { '7' => 'Fixture' } }))
  end
  teardown { Current.reset }

  def json(value)
    { status: 200, headers: { 'Content-Type' => 'application/json' }, body: value.to_json }
  end

  def row(id = 1, **attributes)
    { 'id' => id, 'store_id' => 7, 'user_id' => 22, 'user' => { 'id' => 22, 'email' => 'PRIVATE@example.com' },
      'started_at' => '2026-10-05T09:00:00Z', 'ended_at' => '2026-10-05T17:00:00Z', 'number_of_hours' => 8.0,
      'is_in_progress' => false, 'is_verified' => true, 'deleted_at' => nil, 'updated_at' => '2026-10-06T00:00:00Z' }.merge(attributes.stringify_keys)
  end

  def page(rows, number: 1, last: 1, total: rows.length)
    json(data: rows, current_page: number, last_page: last, total: total)
  end

  def stub_rows(closed = [], open: [])
    stub_request(:get,
      "#{@origin}/api/v1/laborShifts").with(query: { is_in_progress: '0', page: '1',
                                                                per_page: '50' }).to_return(page(closed))
    stub_request(:get,
      "#{@origin}/api/v1/laborShifts").with(query: { is_in_progress: '1', page: '1',
                                                                per_page: '50' }).to_return(page(open))
  end

  test 'complete replay preserves source evidence without creating payable hours or copying private user data' do
    stub_rows([row])
    before = [People::Timesheet.count, People::TimesheetEntry.count, ClockShift.count, People::Payslip.count,
              People::PayRate.count, User.count]
    assert_equal 1, Ctrax::LaborImport.call[:imported]
    first = CtraxLaborShift.first
    assert_equal @employee, first.employee
    assert_equal BigDecimal('8'), first.reported_hours
    assert_equal BigDecimal('8'), first.elapsed_hours
    assert_equal 'imported', first.status
    refute_includes first.source_payload, 'PRIVATE'
    refute_includes first.source_payload_before_type_cast, 'started_at'
    original = first.source_payload_before_type_cast
    assert_no_difference ['CtraxLaborShift.count', 'CtraxLaborObservation.count'] do
      assert_equal 1, Ctrax::LaborImport.call[:shifts]
    end
    assert_equal original, first.reload.source_payload_before_type_cast
    assert_equal before,
      [People::Timesheet.count, People::TimesheetEntry.count, ClockShift.count, People::Payslip.count, People::PayRate.count,
       User.count]
    assert_equal 0,
      EmployeeWorkSummary.new(employee: @employee, from: Date.new(2026, 10, 5),
        to: Date.new(2026, 10, 5)).hours
    assert_not_requested :post, %r{/api/v1/}
  end

  test 'open unknown hours unmatched mismatch invalid and deleted observations remain review history' do
    stub_rows([row(1, number_of_hours: 7.0), row(2, user_id: 999, user: { 'id' => 999 }),
               row(3, started_at: 'missing-offset'), row(4, deleted_at: '2026-10-06T00:00:00Z'), row(6, number_of_hours: nil)],
      open: [row(5, ended_at: nil, is_in_progress: true, number_of_hours: nil)])
    Ctrax::LaborImport.call
    assert_equal({ 1 => 'conflict', 2 => 'unmatched', 3 => 'invalid', 4 => 'deleted', 5 => 'open', 6 => 'invalid' }, CtraxLaborShift.all.to_h do |r|
      [r.external_id.to_i, r.status]
    end)
    assert_equal BigDecimal('7'), CtraxLaborShift.find_by!(external_id: '1').reported_hours
    assert_nil CtraxLaborShift.find_by!(external_id: '5').elapsed_hours
    assert_nil CtraxLaborShift.find_by!(external_id: '5').reported_hours
    assert CtraxLaborShift.find_by!(external_id: '5').started_at
    assert_nil CtraxLaborShift.find_by!(external_id: '2').employee
  end

  test 'changed and missing source records retain original hours timestamps and encrypted evidence' do
    stub_rows([row])
    Ctrax::LaborImport.call
    record = CtraxLaborShift.first
    original = record.source_payload
    stub_rows([row(1, ended_at: '2026-10-05T18:00:00Z', number_of_hours: 9.0)])
    assert_equal 1, Ctrax::LaborImport.call[:changed]
    assert_equal 'changed', record.reload.status
    assert_equal BigDecimal('8'), record.reported_hours
    assert_equal Time.iso8601('2026-10-05T17:00:00Z'), record.ended_at
    assert_equal original, record.source_payload
    assert_equal 9.0, JSON.parse(record.latest_payload)['number_of_hours']
    stub_rows
    assert_equal 1, Ctrax::LaborImport.call[:missing]
    assert_equal original, record.reload.source_payload
    stub_rows([row])
    assert_equal 1, Ctrax::LaborImport.call[:imported]
    assert_equal 'imported', record.reload.status
  end

  test 'later page failure duplicate identities wrong stores and open partition drift publish nothing' do
    stub_rows([row])
    Ctrax::LaborImport.call
    before = CtraxLaborShift.first.attributes
    stub_request(:get,
      "#{@origin}/api/v1/laborShifts").with(query: { is_in_progress: '0', page: '1',
                                                                per_page: '50' }).to_return(page([row], last: 2,
                                                                  total: 2))
    stub_request(:get,
      "#{@origin}/api/v1/laborShifts").with(query: { is_in_progress: '0', page: '2',
                                                                per_page: '50' }).to_return(status: 403)
    assert_raises(Ctrax::LaborImport::Error) { Ctrax::LaborImport.call }
    assert_equal before, CtraxLaborShift.first.attributes
    [[row, row], [row(1, store_id: 8)], [row(1, is_in_progress: true)]].each do |rows|
      stub_rows(rows)
      assert_raises(Ctrax::LaborImport::Error) { Ctrax::LaborImport.call }
      assert_equal before, CtraxLaborShift.first.attributes
    end
    stub_rows([row], open: [row(1, ended_at: nil, is_in_progress: true)])
    assert_raises(Ctrax::LaborImport::Error) { Ctrax::LaborImport.call }
    assert_equal before, CtraxLaborShift.first.attributes
  end

  test 'complete pagination includes all rows and overlap flags source and local time' do
    stub_rows
    stub_request(:get,
      "#{@origin}/api/v1/laborShifts").with(query: { is_in_progress: '0', page: '1',
                                                                per_page: '50' }).to_return(page([row], last: 2,
                                                                  total: 2))
    stub_request(:get,
      "#{@origin}/api/v1/laborShifts").with(query: { is_in_progress: '0', page: '2',
                                                                per_page: '50' }).to_return(page([row(2)], number: 2,
                                                                  last: 2, total: 2))
    result = Ctrax::LaborImport.call
    assert_equal 2, result[:shifts]
    assert_equal ['conflict'], CtraxLaborShift.distinct.pluck(:status)
    assert_equal 0, People::Timesheet.count
    stub_rows([row])
    sheet = @employee.timesheets.create!(period_start: '2026-10-05', period_end: '2026-10-11')
    sheet.entries.create!(worked_on: '2026-10-05', hours: 8)
    Ctrax::LaborImport.call
    assert_equal 'conflict', CtraxLaborShift.find_by!(external_id: '1').status
    assert_equal BigDecimal('8'), sheet.entries.sum(:hours)
  end

  test 'actor freshness and workspace isolation deny import and restrict source visibility' do
    stub_rows([row])
    Ctrax::LaborImport.call
    employee_user = User.create!(tenant: Current.tenant, email: 'ctrax-own@example.com', password: 'password123',
      role: 'employee')
    @employee.update!(user: employee_user)
    assert_equal 1, CtraxLaborShift.visible_to(employee_user).count
    stranger = User.create!(tenant: Current.tenant, email: 'ctrax-other@example.com', password: 'password123',
      role: 'employee')
    assert_empty CtraxLaborShift.visible_to(stranger)
    leader = User.create!(tenant: Current.tenant, email: 'ctrax-leader@example.com', password: 'password123',
      role: 'shift_leader')
    assert_equal 1, CtraxLaborShift.visible_to(leader).count
    assert_raises(Pundit::NotAuthorizedError) { Ctrax::LaborImport.call(actor: leader) }
    users(:regular_user).update!(active: false)
    assert_raises(Pundit::NotAuthorizedError) { Ctrax::LaborImport.call(actor: users(:regular_user)) }
    other = Tenant.create!(name: 'Other labor workspace', subdomain: 'other-labor')
    Current.tenant = other
    assert_empty CtraxLaborShift.all
    assert_empty CtraxLaborShift.visible_to(employee_user)
  end
  test 'credentials and actor are rechecked after reads and before publication' do
    stub_rows([row])
    Ctrax::LaborImport.call
    before = CtraxLaborShift.first.attributes
    stub_request(:get, "#{@origin}/api/v1/laborShifts").with(query: { is_in_progress: '1', page: '1', per_page: '50' }).to_return do
      @connection.update!(credentials_json: { api_url: @origin, api_username: 'rotated', api_password: 'secret' }.to_json)
      page([])
    end
    assert_raises(Ctrax::LaborImport::Error) { Ctrax::LaborImport.call }
    assert_equal before, CtraxLaborShift.first.attributes
    stub_request(:get, "#{@origin}/api/v1/laborShifts").with(query: { is_in_progress: '1', page: '1', per_page: '50' }).to_return do
      users(:regular_user).update!(active: false)
      page([])
    end
    assert_raises(Pundit::NotAuthorizedError) { Ctrax::LaborImport.call }
    assert_equal before, CtraxLaborShift.first.attributes
  end

  test 'foreign employee identities cannot map a local source shift' do
    other = Tenant.create!(name: 'Foreign identity store', subdomain: 'foreign-labor-identity')
    worker = People::Employee.unscoped.create!(tenant: other, first_name: 'Private', last_name: 'Person')
    EmployeeSourceIdentity.unscoped.create!(tenant: other, employee: worker, source: 'ctrax', external_id: 'fixture.api.cannatrax.net/999')
    stub_rows([row(1, user_id: 999, user: { 'id' => 999 })])
    assert_equal 1, Ctrax::LaborImport.call[:unmatched]
    assert_nil CtraxLaborShift.first.employee_id
    assert_equal 0, CtraxLaborShift.unscoped.where(tenant: other).count
  end
  test 'append only observations preserve every correction reversal and missing transition' do
    stub_rows([row])
    Ctrax::LaborImport.call
    record = CtraxLaborShift.first
    original = record.source_payload
    [9.0, 10.0, 8.0].each do |hours|
      end_at = Time.iso8601('2026-10-05T09:00:00Z') + hours.hours
      stub_rows([row(1, ended_at: end_at.iso8601, number_of_hours: hours)])
      Ctrax::LaborImport.call
    end
    assert_equal [8.0, 9.0, 10.0, 8.0], record.observations.order(:sequence).map { |event| event.record_data['number_of_hours'] }
    assert_equal [1, 2, 3, 4], record.observations.order(:sequence).pluck(:sequence)
    assert_equal original, record.reload.source_payload
    assert_equal BigDecimal('8'), record.reported_hours
    stub_rows
    Ctrax::LaborImport.call
    assert_equal 'missing', record.observations.order(:sequence).last.status
    assert_no_difference 'CtraxLaborObservation.count' do
      Ctrax::LaborImport.call
    end
    stub_rows([row])
    Ctrax::LaborImport.call
    assert_equal 'imported', record.observations.order(:sequence).last.status
    assert_equal 6, record.observations.count
    event = record.observations.first
    refute_includes event.payload_before_type_cast, 'number_of_hours'
    assert_raises(ActiveRecord::ReadOnlyRecord) { event.update!(payload: '{}') }
    assert_raises(ActiveRecord::ReadOnlyRecord) { event.destroy! }
  end

  test 'open closure retains original unknown hours and exposes current clock evidence in ledger' do
    stub_rows([], open: [row(1, ended_at: nil, is_in_progress: true, number_of_hours: nil)])
    Ctrax::LaborImport.call
    record = CtraxLaborShift.first
    assert_nil record.reported_hours
    assert_nil record.ended_at
    stub_rows([row])
    Ctrax::LaborImport.call
    assert_equal 'changed', record.reload.status
    assert_nil record.reported_hours
    assert_nil record.ended_at
    assert_equal 8.0, record.latest_record['number_of_hours']
    assert_equal false, record.latest_record['is_in_progress']
    assert_equal 2, record.observations.count
    assert_equal [nil, '2026-10-05T17:00:00Z'], record.observations.order(:sequence).map { |event| event.record_data['ended_at'] }
    assert_equal 0, People::TimesheetEntry.count
    assert_equal 0, People::Payslip.count
  end
  test 'native null store history is quarantined only with exact tenant employee mapping and never assigned a store' do
    stub_rows([row(1, store_id: nil), row(2, store_id: nil, user: nil)])
    result = Ctrax::LaborImport.call
    assert_equal 2, result[:shifts]
    assert_equal ['unassigned'], CtraxLaborShift.distinct.pluck(:status)
    assert_equal [nil, nil], CtraxLaborShift.order(:id).pluck(:store_id)
    assert CtraxLaborShift.all.all? { |record| record.issue.include?('Source store not supplied') && record.employee_id == @employee.id }
    assert CtraxLaborShift.all.all? { |record| record.latest_record['store_id'].nil? }
    stub_rows
    Ctrax::LaborImport.call
    assert CtraxLaborShift.all.all? { |record| record.status == 'unassigned' && record.issue.include?('Not returned') }
    stub_rows([row(1, store_id: nil)])
    Ctrax::LaborImport.call
    record = CtraxLaborShift.find_by!(external_id: '1')
    assert_equal 'unassigned', record.status
    assert_equal 3, record.observations.count
    assert_equal 0, People::TimesheetEntry.count
  end

  test 'null store without exact local native employee identity and unknown numeric stores reject whole read' do
    foreign = Tenant.create!(name: 'Foreign null store', subdomain: 'foreign-null-store')
    worker = People::Employee.unscoped.create!(tenant: foreign, first_name: 'Private', last_name: 'Worker')
    EmployeeSourceIdentity.unscoped.create!(tenant: foreign, employee: worker, source: 'ctrax', external_id: 'fixture.api.cannatrax.net/999')
    [row(1, store_id: nil, user_id: 998, user: nil), row(1, store_id: nil, user_id: 999, user: { 'id' => 999 }), row(1, store_id: 8)].each do |source_row|
      stub_rows([source_row])
      assert_raises(Ctrax::LaborImport::Error) { Ctrax::LaborImport.call }
      assert_equal 0, CtraxLaborShift.count
      assert_equal 0, CtraxLaborObservation.count
    end
  end
end
