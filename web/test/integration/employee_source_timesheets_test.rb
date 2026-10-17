# frozen_string_literal: true

require 'test_helper'

class EmployeeSourceTimesheetsTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    @reviewer = User.create!(tenant: @tenant, email: 'source-reviewer@example.invalid', password: 'password123', role: 'shift_leader')
    @user = User.create!(tenant: @tenant, email: 'source-worker@example.invalid', password: 'password123', role: 'employee')
    @worker = People::Employee.create!(first_name: 'Own', last_name: 'Source', user: @user)
    @inactive = People::Employee.create!(first_name: 'Former', last_name: 'Source')
    @inactive.terminate!
    @own_square = square_card('own-square', @worker)
    @other_square = square_card('former-square', @inactive)
    @unmatched_square = square_card('held-square', nil, 'unmatched')
    @own_ctrax = ctrax_shift('own-ctrax', @worker)
    @other_ctrax = ctrax_shift('former-ctrax', @inactive)
    @open_ctrax = ctrax_shift('open-ctrax', nil, 'open', in_progress: true, ended_at: nil)
    @held_ctrax = ctrax_shift('held-ctrax', nil, 'unmatched')
  end

  teardown { Current.reset }

  def sign_in(user = @reviewer)
    post login_path, params: { email: user.email, password: 'password123' }
    Current.tenant = @tenant
  end

  def square_card(id, employee, status = 'imported')
    SquareTimecard.create!(external_id: id, employee: employee, import_status: status, last_seen_at: Time.current,
      started_at: '2026-10-05T09:00:00-04:00', ended_at: '2026-10-05T17:00:00-04:00', timezone: 'America/New_York',
      payable_seconds: 28_800, imported_at: status == 'imported' ? Time.current : nil,
      source_payload: '{"private_source_marker":"never-display"}', latest_payload: '{"private_source_marker":"never-display"}')
  end

  def ctrax_shift(id, employee, status = 'imported', **attributes)
    payload = { started_at: '2026-10-06T09:00:00-04:00', ended_at: attributes.fetch(:ended_at, '2026-10-06T17:00:00-04:00'),
      number_of_hours: status == 'open' ? nil : 7.0, is_in_progress: attributes.fetch(:in_progress, false), is_verified: false,
      private_source_marker: 'never-display' }.to_json
    CtraxLaborShift.create!({ source_origin: 'https://source.example.invalid', external_id: id, store_id: 'store-one', user_external_id: "user-#{id}",
      employee: employee, status: status, last_seen_at: Time.current, original_digest: 'original', latest_digest: 'latest',
      started_at: '2026-10-06T09:00:00-04:00', ended_at: '2026-10-06T17:00:00-04:00', reported_hours: status == 'open' ? nil : 7, elapsed_hours: status == 'open' ? nil : 8,
      in_progress: false, verified: false, source_payload: payload, latest_payload: payload }.merge(attributes))
  end

  test 'reviewers find every source including inactive unmatched and open history' do
    %w[admin manager shift_leader].each do |role|
      @reviewer.update!(role: role)
      sign_in
      get people_timesheets_path
      assert_response :success
      assert_select 'a[href=?]', people_timesheets_path(status: 'all'), text: 'View all Rupert timesheets'
      assert_select 'a[href=?]', people_square_timesheets_path, text: 'View Square history'
      assert_select 'a[href=?]', people_ctrax_timesheets_path, text: 'View C-Trax history'
      get people_square_timesheets_path
      assert_response :success
      assert_select 'a[href=?]', people_square_timesheet_path(@other_square)
      assert_select 'a[href=?]', people_square_timesheet_path(@unmatched_square)
      assert_select 'select[name="employee_id"] option', text: 'Former Source (inactive)'
      get people_ctrax_timesheets_path
      assert_response :success
      assert_select 'a[href=?]', people_ctrax_timesheet_path(@other_ctrax)
      assert_select 'a[href=?]', people_ctrax_timesheet_path(@open_ctrax)
      assert_select 'a[href=?]', people_ctrax_timesheet_path(@held_ctrax)
      assert_select 'select[name="employee_id"]'
      assert_includes response.body, 'Reported and elapsed hours differ'
      refute_includes response.body, 'private_source_marker'
    end
  end

  test 'source filters and CSV keep unmatched history visible without raw payloads' do
    sign_in
    get people_square_timesheets_path, params: { employee_id: 'unmatched', status: 'unmatched' }
    assert_select 'a[href=?]', people_square_timesheet_path(@unmatched_square)
    assert_select 'a[href=?]', people_square_timesheet_path(@own_square), count: 0
    get people_ctrax_timesheets_path, params: { employee_id: @inactive.id, from: '2026-10-06', to: '2026-10-06' }
    assert_select 'a[href=?]', people_ctrax_timesheet_path(@other_ctrax)
    assert_select 'a[href=?]', people_ctrax_timesheet_path(@own_ctrax), count: 0
    get people_ctrax_timesheets_path(format: :csv), params: { employee_id: 'unmatched', status: 'open' }
    assert_response :success
    assert_includes response.body, 'open-ctrax'
    refute_includes response.body, 'own-ctrax'
    refute_includes response.body, 'held-ctrax'
    refute_includes response.body, 'private_source_marker'
    get people_ctrax_timesheets_path, params: { from: 'not-a-date' }
    assert_redirected_to people_ctrax_timesheets_path
    get people_ctrax_timesheet_path(@own_ctrax)
    assert_response :success
    assert_includes response.body, 'Source-reported hours'
    assert_includes response.body, 'Elapsed hours'
    assert_includes response.body, 'excluded from Rupert payroll'
    refute_includes response.body, 'private_source_marker'
  end

  test 'account administrator retains read-only history review without approval permission' do
    @reviewer.update!(role: 'admin')
    @reviewer.update_permission_overrides!(%w[dashboard.read users.write timesheets.read])
    refute @reviewer.can_review_timesheets?
    sign_in
    get people_square_timesheets_path
    assert_response :success
    assert_select 'a[href=?]', people_square_timesheet_path(@other_square)
    get people_ctrax_timesheets_path
    assert_response :success
    assert_select 'a[href=?]', people_ctrax_timesheet_path(@other_ctrax)
  end

  test 'latest closed punches and changed hours are visible alongside immutable original and all observations' do
    original = @open_ctrax.latest_record
    latest = original.merge('ended_at' => '2026-10-06T18:00:00-04:00', 'number_of_hours' => 9.0, 'is_in_progress' => false, 'is_verified' => true)
    @open_ctrax.observations.create!(sequence: 1, observed_at: 1.hour.ago, digest: 'first', payload: { record: original, status: 'open', issue: 'Open source shift' }.to_json)
    @open_ctrax.update!(latest_payload: latest.to_json, latest_digest: 'changed', status: 'changed')
    @open_ctrax.observations.create!(sequence: 2, observed_at: Time.current, digest: 'second', payload: { record: latest, status: 'changed', issue: 'Original retained' }.to_json)
    sign_in
    get people_ctrax_timesheets_path
    assert_response :success
    assert_includes response.body, 'Latest source-reported: 9.00h'
    assert_select 'section.grid div', text: /In progress\s*0/
    get people_ctrax_timesheet_path(@open_ctrax)
    assert_select '[aria-label="Latest source observation"] dd', text: '9.00', count: 2
    assert_select '[aria-label="Original source observation"] dd', text: 'Not available', minimum: 2
    assert_select '[data-observation]', count: 2
    assert_includes response.body, 'Source verification is not Rupert approval'
    get people_ctrax_timesheet_path(@open_ctrax, format: :csv)
    assert_response :success
    rows = CSV.parse(response.body, headers: true)
    assert_equal 2, rows.length
    assert_equal %w[open changed], rows.map { |row| row['Status'] }
    assert_equal '9.0', rows[1]['Source-reported hours']
    assert_equal '2026-10-06T18:00:00-04:00', rows[1]['Clock-out']
    refute_includes response.body, 'private_source_marker'
    sign_in(@user)
    get people_ctrax_timesheet_path(@open_ctrax, format: :csv)
    assert_response :not_found
  end

  test 'open and changed Square punches and breaks display safely without exposing source wage data' do
    payload = { 'start_at' => '2026-10-07T09:00:00-04:00', 'end_at' => nil, 'timezone' => 'America/New_York', 'status' => 'OPEN',
      'wage' => { 'hourly_rate' => { 'amount' => 987654, 'currency' => 'USD' } },
      'breaks' => [{ 'name' => '=PRIVATE <script>break</script>', 'start_at' => '2026-10-07T12:00:00-04:00', 'end_at' => '2026-10-07T12:30:00-04:00', 'is_paid' => false }] }
    @own_square.update!(started_at: nil, ended_at: nil, imported_at: nil, import_status: 'open', latest_payload: payload.to_json)
    sign_in
    get people_square_timesheets_path
    assert_response :success
    assert_select 'a[href=?]', people_square_timesheet_path(@own_square), text: /Oct 7, 2026/
    get people_square_timesheet_path(@own_square)
    assert_select '[aria-label="Latest Square punches"] dd', text: 'OPEN'
    assert_select '[data-source-break]', count: 1
    assert_includes response.body, '&lt;script&gt;break&lt;/script&gt;'
    refute_includes response.body, '<script>break</script>'
    refute_includes response.body, '987654'
    refute_includes response.body, 'hourly_rate'
    payload.merge!('end_at' => '2026-10-07T18:00:00-04:00', 'status' => 'CLOSED')
    @own_square.update!(import_status: 'changed', latest_payload: payload.to_json)
    get people_square_timesheet_path(@own_square, format: :csv)
    assert_response :success
    rows = CSV.parse(response.body, headers: true)
    assert_equal '2026-10-07T18:00:00-04:00', rows[0]['Clock-out']
    assert_equal 'Latest break punches', rows[1]['Record type']
    assert_equal "'=PRIVATE <script>break</script>", rows[1]['Break name']
    assert_equal 'false', rows[1]['Paid break']
    refute_includes response.body, '987654'
    get people_square_timesheets_path(format: :csv)
    assert_includes response.body, 'Latest break punches'
    assert_includes response.body, '2026-10-07T18:00:00-04:00'
    refute_includes response.body, 'hourly_rate'
    sign_in(@user)
    get people_square_timesheet_path(@other_square, format: :csv)
    assert_response :not_found
  end

  test 'employee history ignores forged employee filters and denies other employees details' do
    sign_in(@user)
    [[people_square_timesheets_path, people_square_timesheet_path(@own_square), people_square_timesheet_path(@other_square)],
      [people_ctrax_timesheets_path, people_ctrax_timesheet_path(@own_ctrax), people_ctrax_timesheet_path(@other_ctrax)]].each do |index, own, other|
      get index, params: { employee_id: @inactive.id }
      assert_response :success
      assert_equal 'no-store', response.headers['Cache-Control']
      assert_select 'a[href=?]', own
      assert_select 'a[href=?]', other, count: 0
      assert_select 'select[name="employee_id"]', count: 0
      get other
      assert_response :not_found
      get "#{index}.csv", params: { employee_id: @inactive.id }
      assert_response :success
      assert_includes response.body, 'own-'
      refute_includes response.body, 'former-'
      refute_includes response.body, 'held-'
      refute_includes response.body, 'private_source_marker'
    end
  end

  test 'tenant isolation inactive reviewers and revoked review grants are enforced' do
    foreign = Tenant.create!(name: 'Foreign source hours', subdomain: 'foreign-source-hours')
    Current.tenant = foreign
    foreign_square = square_card('foreign-square', nil, 'unmatched')
    foreign_ctrax = ctrax_shift('foreign-ctrax', nil, 'unmatched')
    assert_empty SquareTimecard.visible_to(@reviewer)
    assert_empty CtraxLaborShift.visible_to(@reviewer)
    Current.tenant = @tenant
    sign_in
    get people_square_timesheet_path(foreign_square)
    assert_response :not_found
    get people_ctrax_timesheet_path(foreign_ctrax)
    assert_response :not_found
    @reviewer.update_permission_overrides!(%w[dashboard.read timesheets.read])
    get people_ctrax_timesheets_path
    assert_response :success
    assert_select 'a[href=?]', people_ctrax_timesheet_path(@other_ctrax), count: 0
    @reviewer.update!(active: false)
    assert_empty SquareTimecard.visible_to(@reviewer)
    assert_empty CtraxLaborShift.visible_to(@reviewer)
    get people_ctrax_timesheets_path
    assert_redirected_to login_path
  end

  test 'CSV neutralizes employee text formulas and exposes no wages or upstream writes' do
    @worker.update!(first_name: '=PRIVATE', last_name: 'Formula')
    sign_in
    [people_square_timesheets_path(format: :csv), people_ctrax_timesheets_path(format: :csv)].each do |route|
      get route
      assert_response :success
      assert_includes response.body, "'=PRIVATE Formula"
      refute_includes response.body, 'hourly_rate'
      refute_includes response.body, 'private_source_marker'
    end
    assert_no_difference ['CtraxLaborShift.count', 'People::Timesheet.count', 'People::TimesheetEntry.count'] do
      post people_ctrax_timesheets_path
      assert_response :not_found
      patch people_ctrax_timesheet_path(@own_ctrax), params: { reported_hours: 99 }
      assert_response :not_found
    end
  end
end
