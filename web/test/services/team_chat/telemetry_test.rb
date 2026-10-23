# frozen_string_literal: true

require 'test_helper'
require_relative '../../support/team_chat_helper'

class TeamChatTelemetryTest < ActiveSupport::TestCase
  include TeamChatHelper

  setup do
    Current.tenant = tenants(:default_tenant)
    Current.user = @user = users(:regular_user)
    @room = TeamChat::Room.direct_for(@user)
    @room.update!(assistant_mode: 'mentions')
    @reply = TeamChat::Post.call(room: @room, user: @user, body: '@rupert hello private secret').reply
    @run = @reply.run
    TeamChat::Execution.any_instance.stubs(:start_watch)
  end
  teardown { Current.reset }

  def rows(kind)
    TeamChat::Telemetry.unscoped.where(run_id: @run.id, kind: kind).order(:id)
  end

  test 'actual streamed provider usage and timings persist without conversation contents' do
    script_model(text: 'Hello there')
    TeamChat::Agent.new(@reply, config: team_chat_config).run
    assert_equal 'succeeded', @run.reload.state
    assert_equal 1, rows('claim').count
    assert_equal 1, rows('inference').count
    assert_equal 1, rows('provider_attempt').count
    assert_equal 1, rows('first_chunk').count
    assert_operator rows('inference').first.duration_ms, :>=, 0
    assert_equal 60, rows('provider_attempt').first.facts['input_tokens']
    assert_equal 12, rows('provider_attempt').first.facts['output_tokens']
    summary = TeamChat::Telemetry.summary(@run)
    assert_equal({ 'reported' => 60, 'complete' => true }, summary['tokens']['input_tokens'])
    assert_nil summary['reported_cost_usd']
    assert_not summary['cost_complete']
    data = TeamChat::Telemetry.unscoped.where(run_id: @run.id).map(&:facts).to_json
    %w[private secret test-key Hello].each { |secret| assert_not_includes data, secret }
  end

  test 'real SDK retry records failed and successful physical attempts without counting both as complete usage' do
    token = @run.claim!
    recorder = TeamChat::TelemetryRecorder.new(@run, token)
    chat = team_chat_config.chat(session: 'test', instrumenter: recorder)
    stub_request(:post, "#{LLM_BASE}/chat/completions").to_return(
      { status: 503, body: '{"error":{"message":"private provider detail"}}' },
      { status: 200, headers: { 'Content-Type' => 'text/event-stream' }, body: sse_for(text: 'Recovered') })
    chat.add_message(role: :user, content: 'secret')
    chat.generate { |_chunk| }
    assert_equal %w[failed succeeded], rows('provider_attempt').pluck(:outcome)
    summary = TeamChat::Telemetry.summary(@run)
    assert_equal 60, summary['tokens']['input_tokens']['reported']
    assert_not summary['tokens']['input_tokens']['complete']
    assert_equal 1, summary['transport_retries']
    assert_equal 2, rows('generation').first.facts['attempts']
    assert_not_includes rows('inference').first.facts.to_json, 'private provider detail'
  end

  test 'reported zero cost is known while absent cost and absent tokens remain unknown' do
    recorder = TeamChat::TelemetryRecorder.new(@run, @run.claim!)
    recorder.instrument('usage.ruby_llm', status: :succeeded, tokens: RubyLLM::Tokens.new(input: 0, output: 0, reported_cost: 0))
    summary = TeamChat::Telemetry.summary(@run)
    assert_equal 0, summary['reported_cost_usd']
    assert summary['cost_complete']
    assert_equal({ 'reported' => 0, 'complete' => true }, summary['tokens']['input_tokens'])
    recorder.instrument('usage.ruby_llm', status: :failed, tokens: RubyLLM::Tokens.new)
    summary = TeamChat::Telemetry.summary(@run)
    assert_not summary['cost_complete']
    assert_not summary['tokens']['input_tokens']['complete']
    assert_nil rows('provider_attempt').last.facts['output_tokens']
  end

  test 'duplicate claims and recovered transcripts do not duplicate accounting and old spans stay interrupted' do
    old_token = @run.claim!
    assert_nil @run.claim!
    recorder = TeamChat::TelemetryRecorder.new(@run, old_token)
    recorder.measure('inference') do
      @run.update!(lease_until: 1.second.ago)
      assert @run.claim!
    end
    assert_equal 2, rows('claim').count
    assert_equal 'interrupted', rows('inference').first.outcome
    assert_equal 0, TeamChat::Telemetry.summary(@run)['provider_attempts']
    assert_nil TeamChat::Telemetry.summary(@run)['reported_cost_usd']
  end

  test 'tool replay is separate from execution and tool failures keep their outcome' do
    token = @run.claim!
    execution = TeamChat::Execution.new(@run, token)
    toolbox = TeamChat::Toolbox.new(user: @user, room: @room, reply: @reply, execution: execution)
    toolbox.call_id = 'one'
    toolbox.call('not_a_tool_private_secret', {})
    toolbox.call('not_a_tool_private_secret', {})
    assert_equal 1, rows('tool').count
    assert_equal 'unknown', rows('tool').first.outcome
    assert_equal 'unknown', rows('tool').first.facts['name']
    assert_equal 1, rows('tool_replay').count
  end

  test 'failure and cancellation receipts do not persist exception messages' do
    recorder = TeamChat::TelemetryRecorder.new(@run, @run.claim!)
    assert_raises(TeamChat::Run::Stopped) do
      recorder.measure('inference') { raise TeamChat::Run::Stopped, 'secret' }
    end
    assert_equal 'cancelled', rows('inference').first.outcome
    assert_equal({ 'error_class' => 'TeamChat::Run::Stopped' }, rows('inference').first.facts)
    @run.cancel!
    assert_equal 'cancelled', TeamChat::Telemetry.summary(@run)['state']
  end
  test 'missing streamed usage remains unknown rather than zero' do
    body = sse_for(text: 'Hello').gsub(/,"usage":\{[^}]+\}/, '')
    stub_request(:post, "#{LLM_BASE}/chat/completions").to_return(
      status: 200, headers: { 'Content-Type' => 'text/event-stream' }, body: body)
    TeamChat::Agent.new(@reply, config: team_chat_config).run
    assert_equal 'succeeded', @run.reload.state
    summary = TeamChat::Telemetry.summary(@run)
    assert_nil summary['tokens']['input_tokens']['reported']
    assert_not summary['tokens']['input_tokens']['complete']
  end

  test 'verifier model usage has a separate stage' do
    recorder = TeamChat::TelemetryRecorder.new(@run, @run.claim!, stage: 'verify')
    stub_request(:post, "#{LLM_BASE}/chat/completions").to_return(
      headers: { 'Content-Type' => 'application/json' },
      body: { model: 'test-model', choices: [{ message: { role: 'assistant', content: '{"checks":[]}' }, finish_reason: 'stop' }],
              usage: { prompt_tokens: 15, completion_tokens: 3 } }.to_json)
    TeamChat::Verify.new(config: team_chat_config, question: 'orders', evidence: ['Orders are complete'],
      draft: 'Orders are complete.', chat_factory: ->(instructions) {
        team_chat_config.chat(session: 'verify', instrumenter: recorder).with_instructions(instructions)
      }).call
    assert_equal ['verify'], rows('provider_attempt').pluck(:stage)
    assert_equal 15, rows('provider_attempt').first.facts['input_tokens']
  end

  test 'CLI reports retain known zero costs and missing usage stays unknown' do
    previous = ENV['ASK_RUPERT_OPENCODE_BIN']
    Dir.mktmpdir do |dir|
      script = File.join(dir, 'opencode')
      File.write(script, <<~SH)
        #!/bin/sh
        echo '{"type":"text","part":{"type":"text","text":"Hello"}}'
        echo '{"type":"step_finish","part":{"cost":0,"tokens":{"input":3,"output":1}}}'
      SH
      File.chmod(0o755, script)
      ENV['ASK_RUPERT_OPENCODE_BIN'] = script
      config = TeamChat::ModelConfig.new({ 'RUPERT_CHAT_PROVIDER' => 'opencode_cli' })
      TeamChat::Agent.new(@reply, config: config).run
      assert_equal 'succeeded', @run.reload.state
      assert_equal 1, rows('cli_inference').count
      assert_equal 3, rows('cli_usage').first.facts['input_tokens']
      assert_equal 0, TeamChat::Telemetry.summary(@run)['reported_cost_usd']
      assert TeamChat::Telemetry.summary(@run)['cost_complete']
      assert_equal 'unknown', rows('cli_inference').first.facts['internal_attempts']
    end
  ensure
    ENV['ASK_RUPERT_OPENCODE_BIN'] = previous
  end

  test 'tenant scope hides telemetry with no current tenant or another tenant' do
    @run.claim!
    assert_equal 1, TeamChat::Telemetry.count
    Current.tenant = nil
    assert_equal 0, TeamChat::Telemetry.count
    assert_equal 1, rows('claim').count
  end

  test 'killing the generation thread cannot turn an unfinished request into success' do
    token = @run.claim!
    recorder = TeamChat::TelemetryRecorder.new(@run, token)
    ready = Queue.new
    thread = Thread.new do
      recorder.measure('inference') do
        ready << true
        sleep 30
      end
    end
    ready.pop
    thread.kill.join
    assert_equal 'interrupted', rows('inference').first.outcome
    assert_not TeamChat::Telemetry.summary(@run)['cost_complete']
  ensure
    thread&.kill&.join
  end

  test 'queue time excludes inference and tool rounds accumulate each physical request once' do
    script_model({ tool: 'where_is', arguments: { query: 'timesheets' } }, { text: 'Open Timesheets.' })
    travel_to @run.created_at + 5.seconds, with_usec: true do
      TeamChat::Agent.new(@reply, config: team_chat_config).run
    end
    summary = TeamChat::Telemetry.summary(@run)
    assert_operator summary['queue_ms'], :>=, 5000
    assert_equal 2, summary['provider_attempts']
    assert_equal 110, summary['tokens']['input_tokens']['reported']
    assert_equal 17, summary['tokens']['output_tokens']['reported']
    assert_equal 0, summary['transport_retries']
    assert_equal 1, rows('tool').count
    assert_equal 'ok', rows('tool').first.outcome
  end

  test 'a missing CLI usage report cannot claim complete zero tokens or cost' do
    token = @run.claim!
    recorder = TeamChat::TelemetryRecorder.new(@run, token)
    recorder.measure('cli_inference', facts: { 'internal_attempts' => 'unknown' }) { 'Text without usage' }
    summary = TeamChat::Telemetry.summary(@run)
    assert_nil summary['reported_cost_usd']
    assert_not summary['cost_complete']
    assert_nil summary['tokens']['input_tokens']['reported']
    assert_not summary['tokens']['input_tokens']['complete']
  end

  test 'failure classification survives a refused credential without its provider message' do
    stub_request(:post, "#{LLM_BASE}/chat/completions").to_return(
      status: 401, body: '{"error":{"message":"private provider secret"}}')
    TeamChat::Agent.new(@reply, config: team_chat_config).run
    assert_equal 'failed', @run.reload.state
    assert_equal 'unauthorized', rows('failure').first.facts['kind']
    assert_equal 'failed', rows('provider_attempt').first.outcome
    assert_not_includes rows('failure').first.facts.to_json, 'private provider secret'
  end

  test 'expiry closes abandoned spans and cannot certify previously reported usage as complete' do
    recorder = TeamChat::TelemetryRecorder.new(@run, @run.claim!)
    recorder.instrument('usage.ruby_llm', status: :succeeded,
      tokens: RubyLLM::Tokens.new(input: 5, output: 2, reported_cost: 0.01))
    recorder.measure('inference') do
      @run.update!(deadline_at: 1.second.ago)
      @run.expire!
    end
    assert_equal 'expired', @run.reload.state
    assert_equal 'interrupted', rows('inference').last.outcome
    assert_nil rows('inference').last.duration_ms
    summary = TeamChat::Telemetry.summary(@run)
    assert_equal 0.01, summary['reported_cost_usd']
    assert_not summary['cost_complete']
    assert_not summary['tokens']['input_tokens']['complete']
  end

  test 'malformed token and cost fields cannot copy provider text into the ledger' do
    recorder = TeamChat::TelemetryRecorder.new(@run, @run.claim!)
    recorder.instrument('usage.ruby_llm', status: :succeeded,
      tokens: RubyLLM::Tokens.new(input: 'private secret', output: -1, reported_cost: 'private secret'))
    facts = rows('provider_attempt').first.facts
    assert_nil facts['input_tokens']
    assert_nil facts['output_tokens']
    assert_nil facts['cost_usd']
    assert_not_includes facts.to_json, 'private secret'
  end
end
