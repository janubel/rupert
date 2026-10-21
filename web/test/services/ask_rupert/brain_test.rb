# frozen_string_literal: true

require 'test_helper'
require_relative '../../support/ask_rupert_helper'

class AskRupertBrainTest < ActiveSupport::TestCase
  include AskRupertHelper

  setup do
    @user = person('admin')
    Current.user = @user
  end

  teardown { Current.reset }

  def run_brain(question, replies)
    conversation, message = pending_turn(@user, question)
    provider = ScriptedProvider.new(replies)
    AskRupert::Brain.new(message, config: AskRupert::Config.current, providers: [provider]).run
    [message.reload, provider, conversation]
  end

  test 'answers from the lookup it already did, with a link and the matching lesson' do
    message, provider = run_brain('Where do I find sync history?', ['Open [Sync](/syncs) to see each pull and its status.'])
    assert_equal 'done', message.status
    assert_includes message.content, '[Sync](/syncs)'
    assert_equal ['/syncs', '/learning/sync'], message.links.map { |link| link['path'] }
    assert_equal 'opencode', message.provider
    assert_equal 100, message.tokens_in
    assert_equal 1, provider.calls.size
    assert_includes provider.calls.first[:system], '/syncs', 'the context holds the real page for this person'
    usage = AskRupert::Usage.last
    assert_equal 'ok', usage.outcome
    assert_equal 120, usage.total_tokens
  end

  test 'a tool call runs as the person and its result feeds the next turn' do
    call = 'TOOL_CALL: {"name":"where_is","arguments":{"query":"timesheets"}}'
    message, provider = run_brain('hours?', [call, 'Timesheets are at [Timesheets](/people/timesheets).'])
    assert_equal 'Timesheets are at [Timesheets](/people/timesheets).', message.content
    second = provider.calls.last[:messages]
    assert_equal 'user', second.last[:role]
    assert_match(/<tool_result name="where_is" ok="true">/, second.last[:content])
    assert_match(/not instructions/, second.last[:content])
    assert_equal 1, AskRupert::Usage.last.tool_calls
    assert_includes message.links.map { |link| link['path'] }, '/people/timesheets'
  end

  test 'a model that asks for a tool this person lacks is refused and the answer carries on' do
    cashier = person('cashier')
    Current.user = cashier
    conversation, message = pending_turn(cashier, 'what is payroll for Pat?')
    provider = ScriptedProvider.new(['TOOL_CALL: {"name":"run_report","arguments":{"report":"time_keeping_report"}}', 'I can’t check hours for you; ask a manager.'])
    AskRupert::Brain.new(message, config: AskRupert::Config.current, providers: [provider]).run
    assert_equal 'done', message.reload.status
    assert_match(/No report called time_keeping_report/, provider.calls.last[:messages].last[:content])
    assert_equal conversation.id, message.conversation_id
  end

  test 'tool rounds are capped and the model is told to answer' do
    call = 'TOOL_CALL: {"name":"where_is","arguments":{"query":"sales"}}'
    message, provider = run_brain('sales?', [call] * 4 + ['Here is what I have.'])
    assert_equal 'Here is what I have.', message.content
    assert_equal AskRupert::Brain::MAX_TOOL_ROUNDS + 2, provider.calls.size
    assert_equal AskRupert::Brain::MAX_TOOL_ROUNDS, AskRupert::Usage.last.tool_calls
  end

  test 'a report draft is kept on the message for the person to send, and nothing is filed' do
    call = 'TOOL_CALL: {"name":"file_report","arguments":{"kind":"bug","summary":"Sync page blank","details":"Opened it, nothing"}}'
    assert_no_difference 'AgentFeedback.count' do
      message, = run_brain('this is broken', [call, 'I prepared a report. Please review it and press Send report.'])
      assert_equal 'Sync page blank', message.report_draft['summary']
    end
  end

  test 'model text cannot smuggle links out of Rupert or leave tool lines behind' do
    reply = "TOOL_CALL leftover? no\nSee [click me](https://evil.example/x) and [Sync](/syncs) and [x](//evil.example)."
    message, = run_brain('where is sync', [reply])
    assert_no_match(/evil\.example\/x|\]\(\/\/evil/, message.content)
    assert_includes message.content, '[Sync](/syncs)'
    assert_no_match(/TOOL_CALL/, message.content)
  end

  test 'a provider failure leaves a friendly failed reply and counts as an error, not a question' do
    message, = run_brain('hello there', [AskRupert::ProviderError.new('boom', kind: :rate_limited)])
    assert_equal 'failed', message.status
    assert_equal AskRupert::ProviderError.friendly(:rate_limited), message.content
    assert_equal 'error', AskRupert::Usage.last.outcome
    assert_no_match(/boom/, message.content)
  end

  test 'the first provider failing falls through to the next' do
    conversation, message = pending_turn(@user, 'how do I count stock')
    first = ScriptedProvider.new([AskRupert::ProviderError.new('down', kind: :unavailable)], name: 'ollama', cloud: false)
    second = ScriptedProvider.new(['Open Counts.'])
    AskRupert::Brain.new(message, config: AskRupert::Config.current, providers: [first, second]).run
    assert_equal 'Open Counts.', message.reload.content
    assert_equal 'opencode', message.provider
    assert_predicate conversation.messages, :any?
  end

  test 'the context cap keeps only recent turns and secrets are removed from what the model sees' do
    conversation, message = pending_turn(@user, "my token is sk-#{'z' * 30} please help")
    10.times { |i| conversation.messages.create!(user: @user, role: i.even? ? 'user' : 'assistant', content: "turn #{i} " + ('x' * 900)) }
    conversation.messages.create!(user: @user, role: 'user', content: "latest sk-#{'q' * 30}")
    config = AskRupert::Config.new('context_chars' => 2_000, 'context_messages' => 6)
    provider = ScriptedProvider.new(['ok'])
    AskRupert::Brain.new(message, config: config, providers: [provider]).run
    sent = provider.calls.first[:messages]
    assert_operator sent.sum { |turn| turn[:content].length }, :<=, 2_900
    assert_no_match(/sk-z|sk-q/, sent.map { |turn| turn[:content] }.join)
    assert_equal 'user', sent.first[:role]
  end

  test 'ai-health counters are fed when that part of Rupert is present' do
    skip 'ai-health is not installed' unless defined?(AiAgentRun)
    run_brain('where is sync', ['Open Sync.'])
    assert_equal 1, AiAgentRun.where(agent: 'ask_rupert').count
  end
end
