# frozen_string_literal: true

require 'test_helper'
require_relative '../support/ask_rupert_helper'

# History for assistants: counts and dates only, gated by finance.read.
class McpHistorySummaryTest < ActionDispatch::IntegrationTest
  include AskRupertHelper

  setup do
    RequestTrace.reset!
    @tenant = tenants(:default_tenant)
    @admin = users(:regular_user)
    Current.tenant = @tenant
    BankStatementLine.create!(document_id: 1, account_label: 'Operating', line_no: 1, posted_on: Date.new(2025, 2, 10), description: 'PRIVATE PAYEE', amount_cents: -123_456, fingerprint: 'h1')
    BankStatementLine.create!(document_id: 1, account_label: 'Operating', line_no: 2, posted_on: Date.new(2025, 6, 10), description: 'ANOTHER', amount_cents: -100, fingerprint: 'h2')
  end

  teardown { Current.reset }

  def issue(scopes:, user: @admin)
    Current.tenant = @tenant
    token, secret = ApiAccessToken.issue(attributes: { name: 'History assistant', scopes: scopes }, user: user.reload, tenant: @tenant)
    [token, secret]
  end

  def call(secret, arguments = {})
    post mcp_path, params: { jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: 'history_summary', arguments: arguments } }.to_json,
      headers: { 'Authorization' => "Bearer #{secret}", 'Content-Type' => 'application/json', 'Accept' => 'application/json, text/event-stream' }
    response.parsed_body.fetch('result')
  end

  test 'the scope is tied to finance.read and the tool is listed only for tokens that have it' do
    assert_equal 'finance.read', ApiAccessToken::SCOPES['finance:read']
    _, secret = issue(scopes: ['finance:read'])
    post mcp_path, params: { jsonrpc: '2.0', id: 1, method: 'tools/list' }.to_json,
      headers: { 'Authorization' => "Bearer #{secret}", 'Content-Type' => 'application/json', 'Accept' => 'application/json, text/event-stream' }
    assert_includes response.parsed_body.dig('result', 'tools').map { |t| t['name'] }, 'history_summary'
    _, other = issue(scopes: ['reports:read'])
    post mcp_path, params: { jsonrpc: '2.0', id: 1, method: 'tools/list' }.to_json,
      headers: { 'Authorization' => "Bearer #{other}", 'Content-Type' => 'application/json', 'Accept' => 'application/json, text/event-stream' }
    assert_not_includes response.parsed_body.dig('result', 'tools').map { |t| t['name'] }, 'history_summary'
  end

  test 'answers what is held for a year and from where, without amounts or rows' do
    _, secret = issue(scopes: ['finance:read'])
    result = call(secret, 'year' => 2025)
    assert_equal false, result['isError']
    bank = result['structuredContent']['sources'].find { |row| row['key'] == 'bank' }
    assert_equal [2, '2025-02-10', '2025-06-10'], [bank['records_in_year'], bank['earliest'], bank['latest']]
    assert_equal %w[2025-03 2025-04 2025-05], bank['empty_months']
    assert_match(/Bank statements 2 lines/, result['content'].first['text'])
    assert_match(/not proof/, result['content'].first['text'])
    body = result.to_json
    assert_not_includes body, 'PRIVATE PAYEE'
    assert_not_includes body, '123456'
    assert_not_includes body, '1,234.56'
  end

  test 'a year with nothing held says so without implying nothing exists' do
    _, secret = issue(scopes: ['finance:read'])
    text = call(secret, 'year' => 2019)['content'].first['text']
    assert_match(/For 2019: no source holds records/, text)
    assert_match(/not proof nothing else exists/, text)
  end

  test 'Ask Rupert offers it only to people with finance access' do
    admin = AskRupert::Tools.new(user: person('admin'))
    assert_includes admin.send(:report_tools).map(&:tool_name), 'history_summary'
    result = admin.call('run_report', { 'report' => 'history_summary', 'arguments' => { 'year' => 2025 } })
    assert result.ok, result.text
    assert_match(/Bank statements 2 lines/, result.text)
    cashier = AskRupert::Tools.new(user: person('cashier'))
    assert_not_includes cashier.send(:report_tools).map(&:tool_name), 'history_summary'
    assert_not cashier.call('run_report', { 'report' => 'history_summary' }).ok
  end
end
