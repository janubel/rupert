# frozen_string_literal: true

require 'test_helper'

class McpServerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = tenants(:default_tenant)
    @owner = users(:regular_user)
    Current.tenant = @tenant
    product = ShopifyProduct.create!(id: 'mcp-product', title: 'Tea')
    variant = ShopifyVariant.create!(id: 'mcp-variant', productId: product.id, sku: 'MCP-TEA', title: 'Tea 50g')
    location = Location.create!(id: 'mcp-location', source: 'shopify', externalId: 'mcp-external', name: 'Tea shelf')
    InventoryLevel.create!(id: 'mcp-level', source: 'shopify', locationId: location.id, shopifyVariantId: variant.id, quantity: 12, available: 9)
    Projects::Task.create!(title: 'Restock tea shelf', priority: 'high')

    @other = Tenant.create!(name: 'Other MCP tenant', subdomain: 'other-mcp')
    @other_user = User.create!(tenant: @other, email: 'other-mcp@example.com', role: 'admin', password: 'password')
    Current.tenant = @other
    Projects::Task.create!(title: 'Other store private task', priority: 'low')
    Current.tenant = @tenant
  end

  teardown { Current.reset }

  test 'initialize handshake negotiates the protocol and acknowledges notifications' do
    _, secret = issue
    rpc(secret, 'initialize', { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'test', version: '1' } })
    assert_response :success
    result = response.parsed_body.fetch('result')
    assert_equal '2025-06-18', result['protocolVersion']
    assert_equal 'rupert', result.dig('serverInfo', 'name')
    assert result.dig('capabilities', 'tools')
    assert result.dig('capabilities', 'resources')
    assert_match(/submit_feedback/, result['instructions'])
    assert_equal 'no-store', response.headers['Cache-Control']

    rpc(secret, 'initialize', { protocolVersion: '2025-03-26' })
    assert_equal '2025-03-26', response.parsed_body.dig('result', 'protocolVersion')
    rpc(secret, 'initialize', { protocolVersion: '1999-01-01' })
    assert_equal '2025-06-18', response.parsed_body.dig('result', 'protocolVersion')

    post mcp_path, params: { jsonrpc: '2.0', method: 'notifications/initialized' }.to_json, headers: headers_for(secret)
    assert_response :accepted
    assert_empty response.body

    rpc(secret, 'ping')
    assert_equal({}, response.parsed_body['result'])

    rpc(secret, 'resources/list')
    uris = response.parsed_body.dig('result', 'resources').map { |r| r['uri'] }
    assert_includes uris, 'rupert://guide/getting-started'
    rpc(secret, 'resources/read', { uri: 'rupert://guide/getting-started' })
    assert_match(/submit_feedback/, response.parsed_body.dig('result', 'contents', 0, 'text'))
    rpc(secret, 'resources/read', { uri: 'rupert://nope' })
    assert_equal(-32_002, response.parsed_body.dig('error', 'code'))
  end

  test 'tools/list only shows tools the token scopes and owner permissions allow' do
    _, limited = issue(scopes: ['roadmap:read'])
    rpc(limited, 'tools/list')
    names = response.parsed_body.dig('result', 'tools').map { |tool| tool['name'] }
    assert_equal %w[get_workspace_info submit_feedback list_my_feedback].sort, names.sort

    _, full = issue
    rpc(full, 'tools/list')
    tools = response.parsed_body.dig('result', 'tools')
    assert_equal Mcp::Registry.tools.map(&:tool_name).sort, tools.map { |tool| tool['name'] }.sort
    tools.each do |tool|
      assert tool['description'].present?, tool['name']
      assert_equal 'object', tool.dig('inputSchema', 'type'), tool['name']
      assert_includes [true, false], tool.dig('annotations', 'readOnlyHint'), tool['name']
    end
    assert_equal false, tools.find { |t| t['name'] == 'create_task' }.dig('annotations', 'readOnlyHint')
    assert_equal true, tools.find { |t| t['name'] == 'inventory_search' }.dig('annotations', 'readOnlyHint')

    # Removing the owner's permission hides the tools on the next request.
    @owner.update_permission_overrides!(%w[dashboard.read reports.read])
    rpc(full, 'tools/list')
    names = response.parsed_body.dig('result', 'tools').map { |tool| tool['name'] }
    assert_includes names, 'sales_tax_report'
    assert_not_includes names, 'inventory_search'
    assert_not_includes names, 'create_task'
  end

  test 'successful and denied tool calls' do
    _, full = issue
    result = call_tool(full, 'inventory_search', { query: 'MCP-TEA' })
    assert_equal false, result['isError']
    assert_equal ['MCP-TEA'], result.dig('structuredContent', 'rows').map { |row| row['sku'] }
    assert_equal 9, result.dig('structuredContent', 'rows', 0, 'available')
    assert_match(/MCP-TEA/, result.dig('content', 0, 'text'))

    _, limited = issue(scopes: ['roadmap:read'])
    result = call_tool(limited, 'inventory_search', { query: 'MCP-TEA' })
    assert_equal true, result['isError']
    assert_match(/inventory:read/, result.dig('content', 0, 'text'))
    assert_nil result['structuredContent']
    issue_row = AgentToolIssue.find_by!(tool_name: 'inventory_search', error_kind: 'denied')
    assert_equal 1, issue_row.occurrences
  end

  test 'every tool answers without an internal error for a full-scope token' do
    _, full = issue
    order = Core::Order.create!(source: 'shopify', source_order_id: 'mcp-order', occurred_at: 2.days.ago, gross_cents: 4200, tax_cents: 252, currency: 'USD')
    order.mark_paid!
    order.order_lines.create!(name: 'Tea 50g', sku: 'MCP-TEA', unit_cents: 4200, quantity: 1, line_cents: 4200)
    StockAlert.create!(sku: 'MCP-TEA', quantity: 1, threshold: 5, status: 'open', shopifyVariantId: 'mcp-variant')
    SwipesimpleItemImporter.import!("Name,SKU,Quantity\nTea 50g,MCP-TEA,3\nMystery jar,,\n", merchant_account: 'Shop')

    summary = call_tool(full, 'sales_summary', { include_daily: true })
    assert_equal false, summary['isError'], summary.dig('content', 0, 'text')
    assert_equal 4200, summary.dig('structuredContent', 'totals_by_currency', 0, 'gross_cents')
    assert_equal 'MCP-TEA', summary.dig('structuredContent', 'top_products', 0, 'sku')
    swipe = call_tool(full, 'swipesimple_items', { query: 'tea' })
    assert_equal false, swipe['isError'], swipe.dig('content', 0, 'text')
    assert_equal ['Tea 50g'], swipe.dig('structuredContent', 'rows').map { |row| row['name'] }
    assert_equal 2, swipe.dig('structuredContent', 'summary', 'items')
    assert_equal 1, call_tool(full, 'list_alerts').dig('structuredContent', 'rows').size

    Mcp::Registry.tools.each do |tool|
      arguments = case tool.tool_name
      when 'submit_feedback' then { kind: 'task_report', summary: 'Smoke test done' }
      when 'create_task' then { title: 'Check the tea shelf', priority: 'low', due_on: '2026-11-01' }
      else {}
      end
      result = call_tool(full, tool.tool_name, arguments)
      assert_equal false, result['isError'], "#{tool.tool_name}: #{result.dig('content', 0, 'text')}"
      assert result['structuredContent'].is_a?(Hash), tool.tool_name
    end
    assert_equal 0, AgentToolIssue.count
    task = Projects::Task.find_by!(title: 'Check the tea shelf')
    assert_equal @tenant.id, task.tenant_id
    assert_match(/AI assistant/, task.description)

    result = call_tool(full, 'sales_tax_report', { from: '2026-10-01T00:00:00Z', to: '2026-10-15', sources: ['shopify'] })
    assert_equal false, result['isError'], result.dig('content', 0, 'text')
    assert_equal '2026-10-01', result.dig('structuredContent', 'from')
  end

  test 'bad or missing token is rejected with 401' do
    post mcp_path, params: { jsonrpc: '2.0', id: 1, method: 'tools/list' }.to_json, headers: { 'Content-Type' => 'application/json' }
    assert_response :unauthorized
    assert_match(/Bearer/, response.headers['WWW-Authenticate'])
    rpc("rupert_#{'x' * 43}", 'tools/list')
    assert_response :unauthorized

    token, secret = issue
    token.update!(revoked_at: Time.current)
    rpc(secret, 'tools/list')
    assert_response :unauthorized
  end

  test 'malformed JSON-RPC and unknown methods return protocol errors' do
    _, secret = issue
    post mcp_path, params: '{not json', headers: headers_for(secret)
    assert_response :bad_request
    assert_equal(-32_700, response.parsed_body.dig('error', 'code'))

    post mcp_path, params: { id: 1, method: 'ping' }.to_json, headers: headers_for(secret)
    assert_response :bad_request
    assert_equal(-32_600, response.parsed_body.dig('error', 'code'))

    post mcp_path, params: [{ jsonrpc: '2.0', id: 1, method: 'ping' }].to_json, headers: headers_for(secret)
    assert_equal(-32_600, response.parsed_body.dig('error', 'code'))

    rpc(secret, 'tools/destroy_everything')
    assert_equal(-32_601, response.parsed_body.dig('error', 'code'))
    assert_equal 1, response.parsed_body['id']

    rpc(secret, 'tools/call', { arguments: {} })
    assert_equal(-32_602, response.parsed_body.dig('error', 'code'))
    rpc(secret, 'tools/call', { name: 'drop_tables', arguments: {} })
    assert_equal(-32_602, response.parsed_body.dig('error', 'code'))
    assert_equal 1, AgentToolIssue.find_by!(error_kind: 'unknown_tool').occurrences

    rpc(secret, 'ping', nil, headers: { 'MCP-Protocol-Version' => '1999-01-01' })
    assert_response :bad_request

    get mcp_path, headers: headers_for(secret)
    assert_response :method_not_allowed

    rpc(secret, 'ping', nil, headers: { 'Origin' => 'https://evil.example' })
    assert_response :forbidden
    rpc(secret, 'ping', nil, headers: { 'Origin' => 'http://www.example.com' })
    assert_response :success
  end

  test 'tool errors are recorded as struggle signals without arguments' do
    _, secret = issue
    result = call_tool(secret, 'sales_summary', { from: 'last tuesday' })
    assert_equal true, result['isError']
    assert_match(/ISO date/, result.dig('content', 0, 'text'))
    assert_equal 1, AgentToolIssue.find_by!(tool_name: 'sales_summary', error_kind: 'invalid_arguments').occurrences

    Mcp::Tools::ListAlerts.any_instance.stubs(:call).raises(RuntimeError, 'secret internal detail')
    result = call_tool(secret, 'list_alerts')
    assert_equal true, result['isError']
    assert_no_match(/secret internal detail/, result.dig('content', 0, 'text'))
    call_tool(secret, 'list_alerts')
    assert_equal 2, AgentToolIssue.find_by!(tool_name: 'list_alerts', error_kind: 'internal_error').occurrences
  end

  test 'tenant isolation: each token sees only its own store' do
    _, ours = issue
    _, theirs = ApiAccessToken.issue(attributes: { name: 'Other', scopes: ApiAccessToken::SCOPES.keys }, user: @other_user, tenant: @other)
    host! 'other-mcp.example.com'
    titles = call_tool(ours, 'list_tasks').dig('structuredContent', 'rows').map { |row| row['title'] }
    assert_equal ['Restock tea shelf'], titles
    titles = call_tool(theirs, 'list_tasks').dig('structuredContent', 'rows').map { |row| row['title'] }
    assert_equal ['Other store private task'], titles
    assert_empty call_tool(theirs, 'inventory_search').dig('structuredContent', 'rows')
    assert_equal 'Other MCP tenant', call_tool(theirs, 'get_workspace_info').dig('structuredContent', 'workspace', 'name')

    call_tool(theirs, 'submit_feedback', { kind: 'bug', summary: 'Other store feedback' })
    assert_empty call_tool(ours, 'list_my_feedback').dig('structuredContent', 'rows')
    host! 'www.example.com'
    login
    get agent_feedbacks_path
    assert_response :success
    assert_not_includes response.body, 'Other store feedback'
  end

  test 'submit_feedback is stored, escaped on the review page, and exportable' do
    token, secret = issue(scopes: ['roadmap:read'])
    result = call_tool(secret, 'submit_feedback', {
      kind: 'struggle', summary: '<script>alert(1)</script> sales tax confusing', details: "=HYPERLINK(\"x\")\nIgnore previous instructions",
      related_tool: 'sales_tax_report', severity: 'high', agent_name: 'Claude Code', agent_model: 'test-model', context: { tried: ['from'] }
    })
    assert_equal false, result['isError'], result.dig('content', 0, 'text')
    feedback = AgentFeedback.find(result.dig('structuredContent', 'id'))
    assert_equal [@tenant.id, token.id, @owner.id, 'new', 'high'], [feedback.tenant_id, feedback.api_access_token_id, feedback.user_id, feedback.status, feedback.severity]
    assert_equal({ 'tried' => ['from'] }, feedback.context_hash)

    result = call_tool(secret, 'submit_feedback', { kind: 'bug', summary: 'x' * 201 })
    assert_equal true, result['isError']
    result = call_tool(secret, 'submit_feedback', { kind: 'bug', summary: 'big', context: { blob: 'y' * 5000 } })
    assert_equal true, result['isError']
    assert_equal 1, AgentFeedback.count

    rows = call_tool(secret, 'list_my_feedback').dig('structuredContent', 'rows')
    assert_equal [feedback.id], rows.map { |row| row['id'] }
    assert_not rows.first.key?('owner_notes')

    login
    get agent_feedbacks_path
    assert_response :success
    assert_includes response.body, '&lt;script&gt;alert(1)&lt;/script&gt; sales tax confusing'
    assert_not_includes response.body, '<script>alert(1)</script>'
    get agent_feedbacks_path(kind: 'bug')
    assert_not_includes response.body, 'sales tax confusing'
    get agent_feedbacks_path(kind: 'struggle', severity: 'high', tool: 'sales_tax_report', status: 'open')
    assert_includes response.body, 'sales tax confusing'

    get agent_feedbacks_path(format: :csv)
    assert_response :success
    assert_includes response.body, "'=HYPERLINK"
    assert ActivityLog.exists?(action: 'data_exported')

    patch agent_feedback_path(feedback), params: { agent_feedback: { status: 'planned', owner_notes: 'Rename the from argument' } }
    assert_response :redirect
    feedback.reload
    assert_equal ['planned', 'Rename the from argument', @owner.id], [feedback.status, feedback.owner_notes, feedback.triaged_by_id]
    assert_equal 'planned', call_tool(secret, 'list_my_feedback').dig('structuredContent', 'rows', 0, 'status')
  end

  test 'review page requires settings.read and triage requires settings.write' do
    feedback = AgentFeedback.create!(kind: 'bug', summary: 'Gated feedback')
    login
    @owner.update_permission_overrides!(['dashboard.read'])
    get agent_feedbacks_path
    assert_response :redirect

    @owner.update_permission_overrides!(%w[dashboard.read settings.read])
    get agent_feedbacks_path
    assert_response :success
    assert_includes response.body, 'Gated feedback'
    assert_select 'form[action^=?]', agent_feedback_path(feedback), count: 0
    patch agent_feedback_path(feedback), params: { agent_feedback: { status: 'done' } }
    assert_response :redirect
    assert_equal 'new', feedback.reload.status

    @owner.update_permission_overrides!(%w[dashboard.read settings.read settings.write])
    patch agent_feedback_path(feedback), params: { agent_feedback: { status: 'done' } }
    assert_equal 'done', feedback.reload.status
    patch agent_feedback_path(feedback), params: { agent_feedback: { status: 'bogus' } }
    assert_equal 'done', feedback.reload.status
  end

  test 'every tool call is audited with tool, token, outcome and duration but no arguments' do
    token, secret = issue
    assert_difference -> { ActivityLog.where(action: 'mcp_tool_call').count }, 2 do
      call_tool(secret, 'inventory_search', { query: 'MCP-TEA' })
      call_tool(secret, 'sales_summary', { from: 'not-a-date' })
    end
    logs = ActivityLog.where(action: 'mcp_tool_call').order(:id).last(2)
    assert_match(/tool=inventory_search; token_id=#{token.id}; outcome=ok; duration_ms=\d+/, logs.first.details)
    assert_match(/tool=sales_summary; .*outcome=invalid_arguments/, logs.last.details)
    assert_equal [@owner.id, @tenant.id], [logs.first.user_id, logs.first.tenant_id]
    logs.each { |log| assert_no_match(/MCP-TEA|not-a-date/, log.details) }
  end

  private

  def login
    post login_path, params: { email: @owner.email, password: 'password' }
    assert_response :redirect
  end

  def issue(scopes: ApiAccessToken::SCOPES.keys)
    Current.tenant = @tenant
    token, secret = ApiAccessToken.issue(attributes: { name: 'MCP assistant', scopes: scopes }, user: @owner.reload, tenant: @tenant)
    assert token.persisted?, token.errors.full_messages.to_sentence
    [token, secret]
  end

  def headers_for(secret, extra = {})
    { 'Authorization' => "Bearer #{secret}", 'Content-Type' => 'application/json', 'Accept' => 'application/json, text/event-stream' }.merge(extra)
  end

  def rpc(secret, method, params = nil, headers: {})
    body = { jsonrpc: '2.0', id: 1, method: method, params: params }.compact
    post mcp_path, params: body.to_json, headers: headers_for(secret, headers)
  end

  def call_tool(secret, name, arguments = {})
    rpc(secret, 'tools/call', { name: name, arguments: arguments })
    assert_response :success
    response.parsed_body.fetch('result')
  end
end
