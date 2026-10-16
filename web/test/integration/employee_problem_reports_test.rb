# frozen_string_literal: true

require 'test_helper'

class EmployeeProblemReportsTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  setup do
    Current.tenant = tenants(:default_tenant)
    @user = User.create!(tenant: Current.tenant, role: 'employee', email: 'problem-worker@example.com', password: 'password123')
    @worker = People::Employee.create!(first_name: 'Problem', last_name: 'Reporter', user: @user)
    @other = People::Employee.create!(first_name: 'Other', last_name: 'Reporter')
  end
  teardown { Current.reset }

  def sign_in(user = @user)
    post login_path, params: { email: user.email, password: user == @user ? 'password123' : 'password' }
    Current.tenant = tenants(:default_tenant)
  end

  test 'employee can report a private pay problem without broader access or duplicate sends' do
    sign_in
    key = SecureRandom.uuid
    assert_no_enqueued_jobs do
      assert_difference 'EmployeeWorkReport.count', 1 do
        2.times do
          post employee_problem_path, params: { work_report: { kind: 'pay', details: 'Please check my recorded hours.', request_key: key, employee_id: @other.id, status: 'resolved', reviewer_id: @user.id } }
          assert_redirected_to employee_reports_path(anchor: 'problems')
        end
      end
    end
    report = EmployeeWorkReport.last
    assert_equal @worker.id, report.employee_id
    assert_equal @user.id, report.requester_id
    assert_equal 'open', report.status
    assert_nil report.reviewer_id
    get employee_reports_path
    assert_response :success
    assert_includes response.body, 'Please check my recorded hours.'
    assert_select 'textarea[name="work_report[details]"]'
    get people_work_reports_path
    assert_response :redirect
    patch people_work_report_path(report), params: { work_report: { status: 'resolved', response: 'Forbidden', lock_version: 0 } }
    assert_nil report.reload.response
    assert_equal 'open', report.status
  end

  test 'own problem history cannot include another worker or workspace reports' do
    Current.tenant = tenants(:default_tenant)
    EmployeeWorkReport.create!(employee: @other, kind: 'pay', details: 'PRIVATE OTHER PROBLEM', request_key: SecureRandom.uuid)
    foreign = Tenant.create!(name: 'Foreign reports', subdomain: 'foreign-work-reports')
    foreign_worker = People::Employee.create!(tenant: foreign, first_name: 'Foreign', last_name: 'Reporter')
    foreign_report = EmployeeWorkReport.create!(tenant: foreign, employee: foreign_worker, kind: 'pay', details: 'PRIVATE FOREIGN PROBLEM', request_key: SecureRandom.uuid)
    sign_in
    get employee_reports_path, params: { employee_id: @other.id, tenant_id: foreign.id }
    refute_includes response.body, 'PRIVATE OTHER PROBLEM'
    refute_includes response.body, 'PRIVATE FOREIGN PROBLEM'
    sign_in(users(:regular_user))
    patch people_work_report_path(foreign_report), params: { work_report: { status: 'resolved', response: 'Wrong tenant', lock_version: 0 } }
    assert_response :not_found
  end

  test 'administrator response appears privately and stale review cannot overwrite it' do
    report = @worker.work_reports.create!(requester: @user, kind: 'time', details: 'Missing Friday hours', request_key: SecureRandom.uuid)
    sign_in(users(:regular_user))
    get people_work_reports_path
    assert_response :success
    assert_equal 'no-store', response.headers['Cache-Control']
    assert_includes response.body, 'Missing Friday hours'
    patch people_work_report_path(report), params: { work_report: { status: 'resolved', response: 'Friday has been checked.', lock_version: 0, employee_id: @other.id, details: 'Overwrite original' } }
    assert_equal 'resolved', report.reload.status
    assert_equal 'Missing Friday hours', report.details
    assert_equal @worker.id, report.employee_id
    patch people_work_report_path(report), params: { work_report: { status: 'open', response: 'Stale response', lock_version: 0 } }
    assert_equal 'Friday has been checked.', report.reload.response
    assert_equal 'resolved', report.status
    sign_in
    get employee_reports_path
    assert_includes response.body, 'Friday has been checked.'
    assert_equal 'no-store', response.headers['Cache-Control']
  end

  test 'invalid problem inputs render the personal form without a partial report' do
    sign_in
    assert_no_difference 'EmployeeWorkReport.count' do
      post employee_problem_path, params: { work_report: { kind: 'invalid', details: 'x' * 2001, request_key: 'not-a-key' } }
    end
    assert_response :unprocessable_entity
    assert_select 'textarea[name="work_report[details]"]'
  end
end
