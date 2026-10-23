# frozen_string_literal: true

require 'test_helper'
require_relative '../support/ops_log_helper'

# What Rupert writes to its log: one structured line per request, events for what
# an operator needs, quiet routine traffic, and never a secret or a personal value.
class OpsLogTest < ActionDispatch::IntegrationTest
  include OpsLogHelper

  CSV_TEXT = "Date,Description,Amount\n2026-10-14,UPS STORE 123,-42.10\n2026-10-14,CARD DEPOSIT,500.00\n2026-10-15,ACME SUPPLY,-120.00\n"

  setup do
    OpsLog::Noise.reset!
    OpsEvent.delete_all
    @tenant = tenants(:default_tenant)
    @admin = users(:regular_user)
    @admin.update!(password: 'password123')
    @cashier = User.create!(email: 'cashier-log@example.com', password: 'password123', role: 'cashier', tenant_id: @tenant.id, name: 'Casey Cashier')
    Current.tenant = @tenant
  end

  teardown { Current.reset }

  def sign_in(user)
    post login_path, params: { email: user.email, password: 'password123' }
  end

  def requests(lines) = ops_events(lines, 'request')

  test 'a signed-in request writes one JSON line with who, what, how long and how big' do
    sign_in(@admin)
    lines = capture_ops_log { get dashboard_path }
    assert_equal 1, lines.size, ops_raw
    line = lines.first
    assert_equal 'request', line['event']
    assert_equal 'info', line['level']
    assert_equal 'GET', line['method']
    assert_equal '/dashboard', line['path']
    assert_equal 'home', line['controller']
    assert_equal 'index', line['action']
    assert_equal 200, line['status']
    assert_equal @admin.id, line['user_id']
    assert_equal @tenant.id, line['tenant_id']
    assert_equal 'admin', line['role']
    assert_equal response.headers['X-Request-Id'], line['request_id']
    assert line['duration_ms'].positive?
    assert line['db_ms'] >= 0
    assert line['view_ms'] >= 0
    assert line['bytes'].positive?
    assert_equal '127.0.0.1', line['ip']
    assert Time.iso8601(line['ts'])
  end

  test 'rails own request lines are replaced, not duplicated, in a structured format' do
    sign_in(@admin)
    capture_ops_log { get dashboard_path }
    assert_no_match(/Started GET|Processing by|Completed 200|Rendered /, ops_raw)
  end

  test 'the rails format keeps the default development lines and writes no request event' do
    sign_in(@admin)
    lines = capture_ops_log(format: 'rails') { get dashboard_path }
    assert_empty requests(lines)
    assert(lines.any? { |line| line['msg'].to_s.start_with?('Started GET') })
  end

  test 'request lines carry parameter names and query names, never values' do
    sign_in(@admin)
    lines = capture_ops_log { get locations_path, params: { q: 'Jane Doe', page: 2 } }
    line = requests(lines).first
    assert_equal %w[q page], line['query_keys']
    refute_includes ops_raw, 'Jane Doe'
    lines = capture_ops_log { post locations_path, params: { location: { name: '', kind: 'Hidden Kind Value' } } }
    assert_equal %w[location.name location.kind], requests(lines).first['params']
    refute_includes ops_raw, 'Hidden Kind Value'
  end

  test 'a rejected form logs the model, the fields and the kinds of error, not the values' do
    sign_in(@admin)
    lines = capture_ops_log { post customers_path, params: { customer: { crm_status: 'Private Status Text', tags: 'x' } } }
    assert_response :unprocessable_entity
    event = ops_events(lines, 'validation_failed').first
    assert_equal 'Core::Customer', event['model']
    assert_equal ['crm_status'], event['fields']
    assert_equal ['inclusion'], event['kinds']
    assert_equal 'customers', event['controller']
    assert_equal 'create', event['action']
    assert_equal @admin.id, event['user_id']
    assert_equal 'warn', requests(lines).first['level']
    refute_includes ops_raw, 'Private Status Text'
    row = OpsEvent.where(kind: 'validation_failed').first
    assert_equal 1, OpsEvent.count, 'the 422 request line must not add a second row for the same problem'
    assert_includes row.summary, 'Customer'
  end

  test 'a permission denial names the policy and who was refused' do
    sign_in(@cashier)
    lines = capture_ops_log { post locations_path, params: { location: { name: 'X' } } }
    event = ops_events(lines, 'permission_denied').first
    assert_equal 'pundit', event['via']
    assert_equal 'ModulePolicy', event['policy']
    assert_equal 'inventory_write?', event['query']
    assert_equal 'cashier', event['role']
    assert_equal @cashier.id, event['user_id']
    assert_equal 1, OpsEvent.where(kind: 'permission_denied').count
  end

  test 'a permission notice on a redirect is a denial even without a policy, and logging does not start a session' do
    sign_in(@cashier)
    lines = capture_ops_log { get system_updates_path }
    denied = ops_events(lines, 'permission_denied').first
    assert denied, ops_raw
    assert_equal 'flash', denied['via']
    reset!
    lines = capture_ops_log { get '/' }
    assert_nil response.headers['Set-Cookie'], 'an anonymous page must not gain a session cookie from the logger'
  end

  test 'failed and successful sign-ins are events without the email address or password' do
    lines = capture_ops_log { post login_path, params: { email: 'someone.private@example.com', password: 'hunter2-secret' } }
    failure = ops_events(lines, 'auth').first
    assert_equal 'warn', failure['level']
    assert_equal 'password', failure['source']
    assert_equal 'failure', failure['status']
    assert_equal 'unknown email', failure['reason']
    assert_match(/\A\h{12}\z/, failure['email_hash'])
    refute_includes ops_raw, 'someone.private'
    refute_includes ops_raw, 'hunter2-secret'
    assert_equal 1, OpsEvent.where(kind: 'auth').count

    lines = capture_ops_log { sign_in(@admin) }
    success = ops_events(lines, 'auth').first
    assert_equal 'success', success['status']
    assert_equal @admin.id, success['user_id']
    assert_nil success['email_hash']

    lines = capture_ops_log { delete logout_path }
    assert_equal 'logout', ops_events(lines, 'auth').first['source']
  end

  test 'an upload logs size, hash and type, an import logs counts, and neither logs contents or the file name' do
    sign_in(@admin)
    Finance::ChartOfAccounts.seed!
    file = Rack::Test::UploadedFile.new(StringIO.new(CSV_TEXT), 'text/csv', original_filename: 'Smith-payroll-oct.csv')
    lines = capture_ops_log { post bank_statements_path, params: { account_label: 'Operating checking', file: file } }
    upload = ops_events(lines, 'upload').first
    assert_equal 'accepted', upload['outcome']
    sent = upload['files'].first
    assert_equal Digest::SHA256.hexdigest(CSV_TEXT), sent['sha256']
    assert_equal CSV_TEXT.bytesize, sent['size']
    assert_equal '.csv', sent['ext']
    assert_equal 'text/csv', sent['type_guess']
    assert_equal 'text/csv', sent['declared_type']
    import = ops_events(lines, 'import').first
    assert_equal 'bank_statement', import['kind']
    assert_equal 'ok', import['outcome']
    assert_equal 3, import['rows']
    assert_equal import['request_id'], upload['request_id']
    ['UPS STORE', 'ACME SUPPLY', 'CARD DEPOSIT', 'Smith', 'payroll', 'Operating checking'].each { |text| refute_includes ops_raw, text }
  end

  test 'a rejected upload is a warning with the reason class and no contents' do
    sign_in(@admin)
    file = Rack::Test::UploadedFile.new(StringIO.new("not,a\nstatement SECRET-ROW-TEXT\n"), 'text/csv', original_filename: 'bad.csv')
    lines = capture_ops_log { post bank_statements_path, params: { account_label: 'x', file: file } }
    assert_response :unprocessable_entity
    assert_equal 'rejected', ops_events(lines, 'upload').first['outcome']
    assert_equal 'rejected', ops_events(lines, 'import').first['outcome']
    assert_includes ops_events(lines, 'import').first['error_class'], 'Error'
    refute_includes ops_raw, 'SECRET-ROW-TEXT'
  end

  test 'tokens, passwords, card numbers, file contents, email bodies and chat text never reach the log' do
    secrets = {
      password: 'Sup3r-Secret-Pass', token: 'tok_live_AB12CDEF34GHIJKL56MNOPQ', card: '4111111111111111',
      csv_row: 'CUSTOMER-ROW-9f3a, 123-45-6789', email_body: 'Dear Mr Payne please wire the funds to routing 021000021',
      chat: 'my neighbour borrowed my car and never returned it', reset_code: 'otp-424242'
    }
    sign_in(@admin)
    lines = capture_ops_log do
      post login_path, params: { email: 'x@example.com', password: secrets[:password], otp: secrets[:reset_code] }
      post feedback_reports_path, params: { feedback_report: { kind: 'bug', description: secrets[:chat], severity: 'low',
        page_url: "https://x.example.com/pay?token=#{secrets[:token]}&card_number=#{secrets[:card]}", page_request_id: 'r-1' } }
      post env_import_settings_path, params: { text: "STRIPE_KEY=#{secrets[:token]}\nNOTE=#{secrets[:email_body]}" }
      post bank_statements_path, params: { account_label: 'x', file: Rack::Test::UploadedFile.new(StringIO.new(secrets[:csv_row]), 'text/csv', original_filename: 'a.csv') }
      get '/api/v1/orders', headers: { 'Authorization' => "Bearer #{secrets[:token]}" }
      get "/warehouse_shares/#{secrets[:token]}"
    end
    assert_operator lines.size, :>=, 5
    secrets.each_value { |value| refute_includes ops_raw, value }
    refute_includes ops_raw, '021000021'
  end

  test 'an unhandled exception is one error line with redacted text and an exception event' do
    sign_in(@admin)
    HomeController.any_instance.stubs(:index).raises(RuntimeError, 'boom for jane@example.com card 4111 1111 1111 1111 "private value"')
    original = Rails.application.env_config['action_dispatch.show_exceptions']
    Rails.application.env_config['action_dispatch.show_exceptions'] = :all
    Rails.application.env_config['action_dispatch.debug_exception_log_level'] = Logger::DEBUG
    lines = capture_ops_log { get dashboard_path, headers: { 'X-Request-Id' => 'redaction-4111' } }
    assert_response :internal_server_error
    line = requests(lines).first
    assert_equal 'error', line['level']
    assert_equal 500, line['status']
    assert_equal 'RuntimeError', line['error_class']
    assert_equal 'home', line['controller']
    assert_equal 'redaction-4111', line['request_id']
    refute_includes line['error_message'], '4111'
    ['jane@example.com', '4111 1111 1111 1111', 'private value'].each { |text| refute_includes ops_raw, text }
    row = OpsEvent.where(kind: 'request').sole
    assert_equal 'error', row.level
    assert_equal 'RuntimeError', row.fields[:error_class]
  ensure
    Rails.application.env_config['action_dispatch.debug_exception_log_level'] = Logger::FATAL
    Rails.application.env_config['action_dispatch.show_exceptions'] = original
  end

  test 'rescued and reported errors are events with the class and a redacted message' do
    error = ArgumentError.new('cannot parse "Jane Roe" for jane@example.com')
    lines = capture_ops_log do
      Rails.error.report(error, handled: true, source: 'application', context: { secret_thing: 'abc123' })
      Rails.error.report(ArgumentError.new('second'), handled: false, source: 'application')
    end
    handled, unhandled = ops_events(lines, 'exception')
    assert_equal 'warn', handled['level']
    assert_equal 'error', unhandled['level']
    assert_equal ['secret_thing'], handled['context_keys']
    refute_includes ops_raw, 'Jane Roe'
    refute_includes ops_raw, 'abc123'
    row = OpsEvent.where(kind: 'exception').sole
    assert_equal 2, row.occurrences, 'repeats of one problem share a row'
    assert_equal 'error', row.level, 'the row keeps the worst level seen'
  end

  test 'a request over the slow threshold is a warning and is kept for the System page' do
    sign_in(@admin)
    ENV['RUPERT_SLOW_REQUEST_MS'] = '0'
    lines = capture_ops_log { get dashboard_path }
    line = requests(lines).first
    assert_equal 'warn', line['level']
    assert_equal true, line['slow']
    assert_equal 1, OpsEvent.where(kind: 'request').count
  ensure
    ENV.delete('RUPERT_SLOW_REQUEST_MS')
  end

  test 'health probes and signed-out page polls write no request line at the default level' do
    lines = capture_ops_log do
      3.times { get '/up' }
      2.times { get '/' }
      get '/login'
    end
    assert_empty requests(lines), ops_raw
  end

  test 'the noise summary reports counts per route' do
    lines = capture_ops_log do
      3.times { get '/up' }
      2.times { get '/' }
      OpsLog::Noise.flush
    end
    summary = ops_events(lines, 'noise_summary').first
    assert_equal 5, summary['total']
    assert_equal({ 'GET /up 200' => 3, 'GET / 200' => 2 }, summary['items'].to_h { |item| [item['what'], item['count']] })
  end

  test 'quiet requests are still written at debug' do
    lines = capture_ops_log(level: Logger::DEBUG) { get '/up' }
    assert_equal 'debug', requests(lines).first['level']
  end

  test 'a failure on a quiet path is logged normally' do
    refute OpsLog::Noise.quiet_request?(method: 'GET', path: '/up', status: 503, user_id: nil, duration_ms: 3)
    refute OpsLog::Noise.quiet_request?(method: 'POST', path: '/internal/workspaces/claim', status: 500, user_id: nil, duration_ms: 3)
    refute OpsLog::Noise.quiet_request?(method: 'GET', path: '/', status: 200, user_id: 5, duration_ms: 3)
    refute OpsLog::Noise.quiet_request?(method: 'GET', path: '/up', status: 200, user_id: nil, duration_ms: 99_999)
    assert OpsLog::Noise.quiet_request?(method: 'POST', path: '/internal/workspaces/claim', status: 204, user_id: nil, duration_ms: 3)
    lines = capture_ops_log { post '/internal/workspaces/claim', as: :json }
    assert_response :unauthorized
    assert_equal 'warn', requests(lines).first['level']
  end

  test 'a 404 is an ordinary info line with no controller' do
    lines = capture_ops_log { get '/definitely/not/here' }
    line = requests(lines).first
    assert_equal 'info', line['level']
    assert_equal 404, line['status']
    assert_nil line['controller']
  end

  test 'token-looking path segments are hidden' do
    assert_equal '/warehouse/:token/items', OpsLog.safe_path('/warehouse/aB3dE5gH7jK9mN1pQ3sT5vX7/items?x=1')
    assert_equal '/api/:token', OpsLog.safe_path('/api/rupert_abcdefghijklmnopqrstuvwxyz')
    assert_equal '/orders/12345/lines', OpsLog.safe_path('/orders/12345/lines')
  end

  test 'a failing job is an error event with class, queue, retries and error class, and no arguments' do
    job_class = Class.new(ApplicationJob) do
      queue_as :default
      def self.name = 'OpsLogProbeJob'
      def perform(secret) = raise(ArgumentError, "bad input #{secret}")
    end
    lines = capture_ops_log do
      assert_raises(ArgumentError) { job_class.perform_now('card-4111111111111111-owner@example.com') }
    end
    event = ops_events(lines, 'job').first
    assert_equal 'error', event['level']
    assert_equal 'OpsLogProbeJob', event['job_class']
    assert_equal 'default', event['queue']
    assert_equal 'failed', event['outcome']
    assert_equal 'ArgumentError', event['error_class']
    assert_equal 1, event['executions']
    assert event['duration_ms'] >= 0
    refute_includes ops_raw, '4111'
    refute_includes ops_raw, 'owner@example.com'
    assert_equal 1, OpsEvent.where(kind: 'job').count
  end

  test 'a quick successful job is counted, not written, at the default level' do
    job_class = Class.new(ApplicationJob) do
      def self.name = 'OpsLogQuickJob'
      def perform; end
    end
    lines = capture_ops_log { job_class.perform_now }
    assert_empty ops_events(lines, 'job')
    lines = capture_ops_log { OpsLog::Noise.flush }
    assert_equal 'job OpsLogQuickJob ok', ops_events(lines, 'noise_summary').first['items'].first['what']
  end

  test 'sync runs are events with source, operation, outcome and duration' do
    lines = capture_ops_log do
      SyncObservability.observe('square', 'catalog') { :done }
      assert_raises(RuntimeError) { SyncObservability.observe('square', 'orders') { raise 'token rejected' } }
    end
    ok, failed = ops_events(lines, 'sync')
    assert_equal %w[square catalog succeeded], ok.values_at('source', 'operation', 'outcome')
    assert_equal %w[square orders failed], failed.values_at('source', 'operation', 'outcome')
    assert_equal 'error', failed['level']
    assert failed['duration_ms'] >= 0
  end

  test 'assistant tool calls are logged by tool and outcome without arguments' do
    Current.tenant = @tenant
    token, secret = ApiAccessToken.issue(attributes: { name: 'Log assistant', scopes: ['system:read'] }, user: @admin.reload, tenant: @tenant)
    lines = capture_ops_log do
      post mcp_path, params: { jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: 'recent_errors', arguments: { limit: 3 } } }.to_json,
        headers: { 'Authorization' => "Bearer #{secret}", 'Content-Type' => 'application/json', 'Accept' => 'application/json, text/event-stream' }
    end
    event = ops_events(lines, 'mcp_tool_call').first
    assert_equal 'recent_errors', event['tool']
    assert_equal 'ok', event['outcome']
    assert_equal token.id, event['token_id']
    refute_includes ops_raw, secret
  end

  test 'rate limited requests are warnings naming the rule' do
    sign_in(@admin)
    lines = capture_ops_log do
      ActiveSupport::Notifications.instrument('throttle.rack_attack', request: Rack::Attack::Request.new(Rack::MockRequest.env_for('/login', method: 'POST', 'rack.attack.matched' => 'login/ip')))
    end
    event = ops_events(lines, 'rate_limited').first
    assert_equal 'login/ip', event['rule']
    assert_equal 'warn', event['level']
  end

  test 'logging never raises into the caller' do
    OpsLog::Activity.stubs(:record).raises(RuntimeError)
    Rails.logger.stubs(:add).raises(RuntimeError)
    assert_nil OpsLog.event('anything', level: :error, a: 1)
  end

  test 'installing the taps and the formatter does not make tagged log blocks run more than once' do
    runs = 0
    Rails.logger.tagged('ops-log-test') { runs += 1 }
    assert_equal 1, runs
  end
end
