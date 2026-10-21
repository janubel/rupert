# frozen_string_literal: true

require 'test_helper'
require_relative '../../support/ask_rupert_helper'

class AskRupertToolsTest < ActiveSupport::TestCase
  include AskRupertHelper

  teardown { Current.reset }

  def tools_for(user, with_conversation: true)
    Current.user = user
    conversation = AskRupert::Conversation.create!(user: user) if with_conversation
    AskRupert::Tools.new(user: user, conversation: conversation)
  end

  test 'what is offered depends on who is asking' do
    assert_includes tools_for(person('admin')).names, 'run_report'
    assert_includes tools_for(person('admin')).names, 'search'
    assert_includes tools_for(person('admin')).names, 'system_status'
    assert_includes tools_for(person('shift_leader')).prompt_section, 'time_keeping_report'
    assert_not_includes tools_for(person('cashier')).prompt_section, 'time_keeping_report'
    assert_includes tools_for(person('cashier')).names, 'where_is'
  end

  test 'a tool the person is not allowed is refused even if the model asks anyway' do
    result = tools_for(person('cashier')).call('run_report', { 'report' => 'sales_summary' })
    assert_not result.ok
    assert_match(/No report called sales_summary is available/, result.text)
    reader = tools_for(person('shift_leader')).call('run_report', { 'report' => 'sales_tax_report' })
    assert_not reader.ok
    unknown_tool = tools_for(person('shift_leader')).call('system_status_all', {})
    assert_match(/No tool named/, unknown_tool.text)
  end

  test 'reports run as the person, so scopes follow their permissions' do
    cashier = tools_for(person('cashier'))
    assert_nil cashier.send(:report_tools).find { |tool| tool.tool_name == 'time_keeping_report' }
    assert cashier.send(:report_tools).map(&:tool_name).include?('list_alerts')
    admin = tools_for(person('admin'))
    result = admin.call('run_report', { 'report' => 'list_alerts', 'arguments' => {} })
    assert result.ok, result.text
    refused = cashier.call('run_report', { 'report' => 'time_keeping_report', 'arguments' => {} })
    assert_not refused.ok
    assert_match(/No report called/, refused.text)
  end

  test 'the stand-in token never carries a write scope' do
    token = AskRupert::ScopedToken.new(person('admin'))
    assert_empty token.scopes & ApiAccessToken::WRITE_SCOPES
    assert_not token.allows?('tasks:write')
    assert_equal 'inventory:read', (token.scopes & ['inventory:read']).first
    employee = AskRupert::ScopedToken.new(person('employee'))
    assert_not employee.usable?
  end

  test 'where_is and how_do_i return links the model can quote' do
    admin = tools_for(person('admin'))
    where = admin.call('where_is', { 'query' => 'timesheets' })
    assert_includes where.text, '/people/timesheets'
    assert_equal 'page', where.links.first[:kind]
    how = admin.call('how_do_i', { 'query' => 'keep sources fresh' })
    assert_includes how.text, '/learning/sync'
  end

  test 'file_report only prepares a draft and files nothing' do
    admin = tools_for(person('admin'))
    assert_no_difference 'AgentFeedback.count' do
      result = admin.call('file_report', { 'kind' => 'bug', 'summary' => 'Totals look off', 'details' => 'Sales vs register' })
      assert result.ok
      assert_equal 'bug', result.draft['kind']
      assert_match(/nothing is filed/, result.text)
    end
  end

  test 'bad arguments come back as text, not exceptions' do
    result = tools_for(person('admin')).call('where_is', { 'query' => '' })
    assert_not result.ok
    assert_match(/Invalid arguments/, result.text)
    unknown = tools_for(person('admin')).call('delete_everything', {})
    assert_not unknown.ok
  end

  test 'system status shows only what the person may see' do
    reader = tools_for(person('reader')).call('system_status', {})
    assert_match(/Build/, reader.text)
    assert_no_match(/Backups|Sync:|Updates/, reader.text)
    super_admin = tools_for(person('super_admin')).call('system_status', {})
    assert_match(/Backups/, super_admin.text)
  end

  test 'the audit trail records the tool and outcome but never what was asked or returned' do
    admin = person('admin')
    tools = tools_for(admin)
    tools.call('where_is', { 'query' => 'secret-launch-codes' })
    row = ActivityLog.where(action: 'ask_rupert_tool').order(:id).last
    assert_match(/tool=where_is; outcome=ok/, row.details)
    assert_no_match(/secret-launch-codes/, row.details)
    assert_equal admin.id, row.user_id
  end

  test 'search results hide contact details from the model' do
    admin = person('admin')
    Current.user = admin
    Core::Customer.create!(tenant_id: admin.tenant_id, first_name: 'Pat', last_name: 'Lee', email: 'pat.lee@example.com', phone: '555-123-4567', source: 'manual', external_id: 'ask-pat')
    result = AskRupert::Tools.new(user: admin).call('search', { 'query' => 'Pat' })
    assert_no_match(/pat\.lee@example\.com|555-123-4567/, result.text)
  end

  test 'other workspaces never leak into search' do
    admin = person('admin')
    other = Tenant.create!(name: 'Other shop', subdomain: 'other-ask-shop')
    Core::Customer.create!(tenant_id: other.id, first_name: 'Zed', last_name: 'Elsewhere', email: 'zed@example.net', source: 'manual', external_id: 'ask-zed')
    Current.tenant = tenants(:default_tenant)
    Current.user = admin
    assert_match(/No results/, AskRupert::Tools.new(user: admin).call('search', { 'query' => 'Zed' }).text)
  end

  test 'where others can read the reply only the two help tools exist, and the rest are refused' do
    admin = person('admin')
    %i[shared direct_help].each do |audience|
      tools = AskRupert::Tools.new(user: admin, audience: audience)
      assert_equal %w[where_is how_do_i].sort, tools.names.sort, audience.to_s
      %w[search run_report system_status file_report].each do |name|
        assert_match(/No tool named #{name}/, tools.call(name, { 'query' => 'abc', 'report' => 'sales_summary', 'kind' => 'bug', 'summary' => 'x' }).text)
      end
    end
    assert_includes AskRupert::Tools.new(user: admin).names, 'search', 'the panel is unchanged'
  end

  test 'a shared reply does not reveal which pages this person lacks, a private one does' do
    cashier = person('cashier')
    shared = AskRupert::Tools.new(user: cashier, audience: :shared).call('where_is', { 'query' => 'payroll' })
    direct = AskRupert::Tools.new(user: cashier, audience: :direct_help).call('where_is', { 'query' => 'payroll' })
    assert_not_includes shared.text, 'not part of this person'
    assert_includes direct.text, 'not part of this person'
  end

  test 'an unknown audience is refused' do
    assert_raises(ArgumentError) { AskRupert::Tools.new(user: person('admin'), audience: :everyone) }
  end
end
