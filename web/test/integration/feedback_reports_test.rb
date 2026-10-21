# frozen_string_literal: true

require 'test_helper'

class FeedbackReportsTest < ActionDispatch::IntegrationTest
  PNG = "\x89PNG\r\n\x1a\n#{'0' * 40}".b

  setup do
    RequestTrace.reset!
    @tenant = tenants(:default_tenant)
    @admin = users(:regular_user)
    @admin.update!(password: 'password123')
    @cashier = User.create!(email: 'cashier@example.com', password: 'password123', role: 'cashier', tenant_id: @tenant.id, name: 'Casey Cashier')
    Current.tenant = @tenant
    @other_tenant = Tenant.create!(name: 'Other', subdomain: 'other-fb')
    @outsider = User.create!(email: 'outsider@example.com', password: 'password123', role: 'admin', tenant_id: @other_tenant.id)
  end

  teardown { Current.reset }

  def sign_in(user)
    post login_path, params: { email: user.email, password: 'password123' }
  end

  def file_report(params = {})
    post feedback_reports_path, params: { feedback_report: { kind: 'bug', description: 'The total on the till is wrong', severity: 'high',
                                                              page_url: 'https://x.example.com/inventory?token=abc&q=tea', page_request_id: 'req-1' }.merge(params) }
  end

  test 'signed-out visitors cannot file or read reports' do
    file_report
    assert_redirected_to login_path
    assert_equal 0, AgentFeedback.unscoped.count
  end

  test 'any signed-in staff member files a report that becomes a task for the owner' do
    sign_in(@cashier)
    assert_difference(['AgentFeedback.count', 'Projects::Task.count'], 1) { file_report }
    assert_response :created
    body = response.parsed_body
    report = AgentFeedback.find(body['id'])
    assert_equal 'app', report.source
    assert_equal @cashier.id, report.user_id
    assert_equal 'bug', report.kind
    assert_equal 'high', report.severity
    assert_equal '/inventory?q=tea&token=%5BFILTERED%5D', report.related_reference
    task = report.task
    assert_equal FeedbackTask::PROJECT_NAME, task.project.name
    assert_equal @admin.id.to_s, task.assignee_id
    assert_equal 'high', task.priority
    assert_includes task.description, "/feedback_reports/#{report.id}"
    assert_equal @admin.id.to_s, task.project.owner_id
    assert_equal 'feedback_reported', ActivityLog.order(:id).last.action
  end

  test 'the second report reuses the project' do
    sign_in(@cashier)
    file_report
    assert_no_difference('Projects::Project.count') { file_report(description: 'Another problem here') }
  end

  test 'bad input is refused with a plain message' do
    sign_in(@cashier)
    file_report(kind: 'deploy')
    assert_response :unprocessable_content
    file_report(description: 'no')
    assert_response :unprocessable_content
    assert_equal 0, AgentFeedback.count
  end

  test 'severity only applies to bugs and unknown values fall back to normal' do
    sign_in(@cashier)
    file_report(kind: 'request', severity: 'high')
    assert_equal 'normal', AgentFeedback.last.severity
    file_report(severity: 'catastrophic')
    assert_equal 'normal', AgentFeedback.last.severity
  end

  test 'a daily limit stops a flood' do
    sign_in(@cashier)
    FeedbackReport::DAILY_LIMIT.times { |i| AgentFeedback.create!(kind: 'bug', summary: "r#{i}", user_id: @cashier.id, source: 'app') }
    file_report
    assert_response :unprocessable_content
  end

  test 'attachments are scrubbed, capped and shown only to administrators' do
    sign_in(@cashier)
    get dashboard_path
    file_report(
      client: { viewport: '390x844', theme: 'dark', evil: 'dropped', language: 'en-US' }.to_json,
      js_errors: [{ message: 'boom password=hunter2', source: '/app.js', line: 3, extra: 'x' }].to_json,
      dom_snapshot: '<main><h1>Inventory</h1><input value="[hidden]"> api_token=SECRET1</main>',
      screenshot: Rack::Test::UploadedFile.new(StringIO.new(PNG), 'image/png', original_filename: 'shot.png')
    )
    assert_response :created
    report = AgentFeedback.last
    kinds = report.attachments.pluck(:kind)
    assert_equal %w[client_context dom_snapshot js_errors screenshot server_log sql_queries], kinds.sort
    context = JSON.parse(report.attachments.find_by(kind: 'client_context').text_body)
    assert_equal '390x844', context['viewport']
    assert_nil context['evil']
    assert_equal BuildInfo.current.revision, context['build']
    assert_equal 'req-1', context['page_request_id']
    assert_not_includes report.attachments.find_by(kind: 'js_errors').text_body, 'hunter2'
    assert_not_includes report.attachments.find_by(kind: 'dom_snapshot').text_body, 'SECRET1'
    assert_includes report.attachments.find_by(kind: 'server_log').text_body, 'Started GET'
    assert_includes report.attachments.find_by(kind: 'sql_queries').text_body, 'SELECT'

    # The reporter sees status only.
    get feedback_report_path(report)
    assert_response :success
    assert_select 'h2', text: 'Attachments', count: 0
    assert_select 'pre', 0
    get screenshot_feedback_report_path(report)
    assert_response :not_found

    delete logout_path
    sign_in(@admin)
    get feedback_report_path(report)
    assert_response :success
    assert_select 'h2', text: 'Attachments'
    assert_select 'summary', text: /Server log lines/
    get screenshot_feedback_report_path(report)
    assert_response :success
    assert_equal 'image/png', response.media_type
    assert_equal 'nosniff', response.headers['X-Content-Type-Options']
  end

  test 'untrusted text is rendered escaped' do
    sign_in(@cashier)
    file_report(description: '<script>alert(1)</script> look')
    report = AgentFeedback.last
    get feedback_report_path(report)
    assert_not_includes response.body, '<script>alert(1)</script>'
    assert_includes response.body, '&lt;script&gt;alert(1)&lt;/script&gt;'
  end

  test 'a fake screenshot is dropped and does not fail the report' do
    sign_in(@cashier)
    file_report(screenshot: Rack::Test::UploadedFile.new(StringIO.new('<svg onload=alert(1)>'), 'image/png', original_filename: 'shot.png'))
    assert_response :created
    assert_nil AgentFeedback.last.attachments.find_by(kind: 'screenshot')
  end

  test 'staff see only their own reports and administrators see all in the store' do
    sign_in(@cashier)
    file_report
    own = AgentFeedback.last
    mine = AgentFeedback.create!(kind: 'question', summary: 'Admin question', user_id: @admin.id, source: 'app')
    get feedback_reports_path
    assert_select 'a', text: own.summary
    assert_select 'a', text: mine.summary, count: 0
    get feedback_report_path(mine)
    assert_response :not_found

    delete logout_path
    sign_in(@admin)
    get feedback_report_path(own)
    assert_response :success
  end

  test 'another store cannot read the report' do
    sign_in(@cashier)
    file_report
    report = AgentFeedback.last
    delete logout_path
    sign_in(@outsider)
    get feedback_report_path(report)
    assert_response :not_found
  end

  test 'session trace holds recent requests with scrubbed lines and queries' do
    sign_in(@admin)
    get dashboard_path, params: { password: 'p4ss', q: 'tea' }
    key = RequestTrace.recent(session[:trace_key]).last
    assert_equal 'GET', key.method
    assert_includes key.path, 'password=[FILTERED]'
    assert key.queries.any?
    assert key.lines.any? { |line| line.include?('Started GET') }
    assert_not RequestTrace.recent(session[:trace_key]).any? { |entry| entry.path.start_with?('/feedback_reports') }
  end

  test 'the report request itself is not traced' do
    sign_in(@cashier)
    get dashboard_path
    before = RequestTrace.recent(session[:trace_key]).size
    file_report
    assert_equal before, RequestTrace.recent(session[:trace_key]).size
  end

  test 'installing the log taps does not make tagged log blocks run more than once' do
    runs = 0
    Rails.logger.tagged('trace-test') { runs += 1 }
    assert_equal 1, runs
  end
end
