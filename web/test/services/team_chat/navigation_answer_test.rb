# frozen_string_literal: true

require 'test_helper'
require 'minitest/mock'
require_relative '../../support/team_chat_helper'

class TeamChatNavigationAnswerTest < ActiveSupport::TestCase
  include TeamChatHelper
  include ActiveJob::TestHelper
  Crash = Class.new(Exception)

  setup do
    Current.tenant = tenants(:default_tenant)
    Current.user = @user = users(:regular_user)
    @room = TeamChat::Room.direct_for(@user)
    @room.update!(assistant_mode: 'mentions')
    TeamChat::Execution.any_instance.stubs(:start_watch)
  end
  teardown { Current.reset }

  def ask(text = '@rupert where are timesheets?', room: @room, parent_id: nil)
    TeamChat::Post.call(room: room, user: @user, body: text, parent_id: parent_id).reply
  end

  def execute(reply, config: team_chat_config)
    TeamChat::Agent.new(reply, config: config).run
    reply.reload
  end

  test 'a direct answer has a verified link and records skipped inference without invented model usage' do
    reply = ask
    assert_no_difference 'AiAgentRun.count' do
      execute(reply)
    end
    assert_equal 'Open [Timesheets](/people/timesheets).', reply.body
    assert_equal 'succeeded', reply.run.reload.state
    assert_equal 'direct_navigation', reply.meta['engine']
    assert_nil reply.meta['model']
    assert_nil reply.meta['tokens_in']
    assert_equal 'local', reply.answer_timing[:where]
    assert_nil reply.answer_timing[:model]
    summary = TeamChat::Telemetry.summary(reply.run)
    assert_equal 'not_applicable', summary['inference']
    assert_equal 'not_applicable', summary['cost_status']
    assert_equal 0, summary['provider_attempts']
    assert_equal 0, summary['cli_invocations']
    assert_nil summary['reported_cost_usd']
    assert_nil summary.dig('tokens', 'input_tokens', 'reported')
    assert_equal 1, TeamChat::Telemetry.where(run_id: reply.run.id, kind: 'tool').count
    assert_not_requested :post, "#{LLM_BASE}/chat/completions"
    assert_not TeamChat::ModelScores.call.any? { |row| row.engine == 'direct_navigation' }
  end

  test 'explicit navigation forms and exact synonyms use the page guide' do
    ['@rupert where is the timesheets page?', 'Where can I find timesheets?', 'How do I get to Timesheets?',
     'Please open Timesheets.', 'Go to timesheets', 'Take me to the timesheets screen', 'Where’s Timesheets?'].each do |text|
      reply = ask("@rupert #{text.sub(/\A@rupert\s+/, '')}")
      execute(reply)
      assert_equal 'direct_navigation', reply.meta['engine'], text
      assert_includes reply.body, '](/people/timesheets)', text
    end
    reply = ask('@rupert where is stock?')
    execute(reply)
    assert_equal 'direct_navigation', reply.meta['engine']
    assert_includes reply.body, '](/inventory)'
  end

  test 'ambiguous mixed negated unknown and data requests fall back to the actual agent' do
    ['Where are hours?', 'Where are timesheets and inventory?', 'Where are timesheets? Also explain how to approve them.',
     "Where are timesheets?\nCreate a task too.", 'Do not open timesheets.', 'Show me sales.', 'Where is the lunar base?',
     'Open payroll and close the pay run.', 'Where are timesheets for yesterday?', 'Where is /people/timesheets?', 'Where is time?', 'Where is new?', 'Where are people?'].each do |text|
      requests = script_model(text: 'The agent is handling this request.')
      reply = ask("@rupert #{text}")
      execute(reply)
      assert_equal 'openai', reply.meta['engine'], text
      assert_equal 1, requests.size, text
      assert_equal 'succeeded', reply.run.reload.state, text
      WebMock.reset!
    end
  end

  test 'a thread remains with the agent even when its last sentence looks navigational' do
    parent = @room.messages.create!(author_kind: 'person', user: @user, body: 'Explain the approval workflow.')
    requests = script_model(text: 'The agent handles this conversation.')
    reply = ask(parent_id: parent.id)
    execute(reply)
    assert_equal 1, requests.size
    assert_equal 'openai', reply.meta['engine']
  end

  test 'unavailable destinations are not directly linked or disclosed' do
    @user.update_permission_overrides!(%w[settings.write dashboard.read])
    requests = script_model(text: 'I cannot open that page for you.')
    reply = ask('@rupert where is payroll?')
    execute(reply)
    assert_equal 1, requests.size
    assert_equal 'openai', reply.meta['engine']
    assert_not_includes reply.body, '/people/pay_runs'
  end

  def with_lookup_hook(hook)
    lookup = AskRupert::Tools.new(user: @user)
    proxy = Object.new
    proxy.define_singleton_method(:call) do |name, args|
      result = lookup.call(name, args)
      hook.call
      result
    end
    AskRupert::Tools.stub(:new, ->(**_args) { proxy }) { yield }
  end

  test 'revoked access after lookup cannot publish a page from cached permissions' do
    reply = ask
    assert AskRupert::Guide.new(@user).permitted_pages.any? { |page| page.key == 'timesheets' }
    with_lookup_hook(-> { @user.update_permission_overrides!(%w[settings.write dashboard.read]) }) { execute(reply) }
    assert_equal 'cancelled', reply.run.reload.state
    assert_equal TeamChat::Execution::ACCESS_CHANGED, reply.body
    assert_not_includes reply.body, '/people/timesheets'
    assert_not_requested :post, "#{LLM_BASE}/chat/completions"
  end

  test 'cancellation after lookup prevents final delivery and a duplicate job cannot resume it' do
    reply = ask
    with_lookup_hook(-> { reply.run.cancel! }) { execute(reply) }
    assert_equal 'cancelled', reply.run.reload.state
    assert_equal 'Stopped.', reply.body
    assert_no_difference 'TeamChat::Telemetry.count' do
      execute(reply)
    end
    assert_not_includes reply.body, '/people/timesheets'
  end

  test 'a deadline reached during lookup expires the run before delivery' do
    reply = ask
    with_lookup_hook(-> { reply.run.update!(deadline_at: 1.second.ago) }) { execute(reply) }
    assert_equal 'expired', reply.run.reload.state
    assert_not_includes reply.body, '/people/timesheets'
  end

  test 'an expired queued run never starts the direct lookup' do
    reply = ask
    reply.run.update!(deadline_at: 1.second.ago)
    AskRupert::Tools.expects(:new).never
    execute(reply)
    assert_equal 'expired', reply.run.reload.state
  end

  test 'a checkpointed navigation run recovers without a model or a second answer' do
    reply = ask
    calls = 0
    with_lookup_hook(-> {
                       calls += 1
                       raise Crash if calls == 1 }) do
      assert_raises(Crash) { execute(reply) }
      assert_equal 'direct_navigation', reply.run.reload.configuration['engine']
      assert_equal 'timesheets', reply.run.configuration['page_key']
      reply.run.update!(lease_until: 1.second.ago)
      execute(reply, config: team_chat_config('RUPERT_CHAT_MODEL' => 'changed-unused-model'))
    end
    assert_equal 2, calls
    assert_equal 2, reply.run.reload.attempts
    assert_equal 'succeeded', reply.run.state
    assert_equal 'Open [Timesheets](/people/timesheets).', reply.body
    assert_no_difference 'TeamChat::Telemetry.count' do
      execute(reply)
    end
    assert_not_requested :post, "#{LLM_BASE}/chat/completions"
  end

  test 'recovery rechecks permissions before reusing a pinned destination' do
    reply = ask
    with_lookup_hook(-> { raise Crash }) { assert_raises(Crash) { execute(reply) } }
    reply.run.update!(lease_until: 1.second.ago)
    @user.update_permission_overrides!(%w[settings.write dashboard.read])
    AskRupert::Tools.expects(:new).never
    execute(reply)
    assert_equal 'cancelled', reply.run.reload.state
    assert_not_includes reply.body, '/people/timesheets'
  end

  test 'a previous model route is never reclassified as direct navigation on recovery' do
    reply = ask
    execution = TeamChat::Execution.new(reply.run, reply.run.claim!)
    execution.pin_configuration!(team_chat_config)
    reply.run.update!(lease_until: 1.second.ago)
    requests = script_model(text: 'The original agent route resumed.')
    execute(reply)
    assert_equal 1, requests.size
    assert_equal 'openai', reply.run.reload.configuration['engine']
  end

  test 'a shared request is handed off before direct lookup and private delivery' do
    channel = TeamChat::Room.ensure_defaults!(@user)
    reply = ask(room: channel)
    assert_enqueued_jobs 1, only: TeamChat::ReplyJob do
      execute(reply)
    end
    assert_match(/private Rupert room/, reply.body)
    assert_not_includes reply.body, '/people/timesheets'
    private_reply = @room.messages.where(author_kind: 'assistant', status: 'pending').last
    execute(private_reply)
    assert_equal 'direct_navigation', private_reply.meta['engine']
    assert_equal 'Open [Timesheets](/people/timesheets).', private_reply.body
  end

  test 'an attachment on the persons message keeps the whole request with the agent' do
    reply = ask
    trigger = TeamChat::Message.find(reply.meta['trigger_id'])
    trigger.attachments.create!(room: @room, filename: 'context.txt', content_type: 'text/plain', byte_size: 11, data: 'Review this')
    requests = script_model(text: 'The agent handles the attached context.')
    execute(reply)
    assert_equal 1, requests.size
    assert_equal 'openai', reply.meta['engine']
  end

  test 'a direct answer does not depend on model credentials or configuration' do
    reply = ask
    execute(reply, config: TeamChat::ModelConfig.new({ 'RUPERT_CHAT_PROVIDER' => 'openai' }))
    assert_equal 'succeeded', reply.run.reload.state
    assert_equal 'direct_navigation', reply.meta['engine']
    assert_equal 'Open [Timesheets](/people/timesheets).', reply.body
  end

  test 'a superseded claimant cannot publish or terminalize the successor' do
    reply = ask
    successor = nil
    with_lookup_hook(-> {
      reply.run.update!(lease_until: 1.second.ago)
      successor = reply.run.claim!
    }) { execute(reply) }
    assert successor
    assert_equal successor, reply.run.reload.owner_token
    assert_equal 'running', reply.run.state
    assert reply.pending?
    assert reply.body.blank?
    context = TeamChat::Execution.new(reply.run, successor)
    recorder = TeamChat::TelemetryRecorder.new(reply.run, successor)
    TeamChat::NavigationAnswer.new(context, telemetry: recorder).call(started: Process.clock_gettime(Process::CLOCK_MONOTONIC))
    assert_equal 'succeeded', reply.run.reload.state
    assert_equal 'Open [Timesheets](/people/timesheets).', reply.reload.body
  end

  test 'an unsupported saved navigation version fails closed with no model charge record' do
    reply = ask
    with_lookup_hook(-> { raise Crash }) { assert_raises(Crash) { execute(reply) } }
    reply.run.update!(lease_until: 1.second.ago, configuration: reply.run.configuration.merge('navigation_version' => 999))
    assert_no_difference 'AiAgentRun.count' do
      execute(reply)
    end
    assert_equal 'failed', reply.run.reload.state
    assert_equal 'direct_navigation', reply.meta['engine']
    assert_nil reply.meta['model']
    assert_not_includes reply.body, '/people/timesheets'
    assert_not_requested :post, "#{LLM_BASE}/chat/completions"
  end


  test 'explicit agent comparison and benchmark requests still exercise the model' do
    [{ 'agent' => 'unavailable-explicit-model' }, { 'compare_of' => 123 }, { 'battery' => 'navigation-evaluation' }].each do |metadata|
      reply = ask
      reply.update!(meta: reply.meta.merge(metadata))
      requests = script_model(text: 'The selected model handled this navigation question.')
      execute(reply)
      assert_equal 1, requests.size
      assert_equal 'openai', reply.meta['engine']
      WebMock.reset!
    end
  end
end
