# frozen_string_literal: true

require 'test_helper'
require_relative '../../support/team_chat_helper'

class TeamChatGenerationRetryTest < ActiveSupport::TestCase
  include TeamChatHelper

  setup do
    Current.tenant = tenants(:default_tenant)
    Current.user = @user = users(:regular_user)
    @room = TeamChat::Room.direct_for(@user)
    @room.update!(assistant_mode: 'mentions')
    @reply = TeamChat::Post.call(room: @room, user: @user, body: '@rupert explain how I can organize my work').reply
    @run = @reply.run
    TeamChat::Execution.any_instance.stubs(:start_watch)
  end
  teardown { Current.reset }

  def refusal(status = 503, headers = {})
    { status: status, headers: headers, body: '{"error":{"message":"temporary private provider detail"}}' }
  end

  def success(text = 'Recovered answer')
    { status: 200, headers: { 'Content-Type' => 'text/event-stream' }, body: sse_for(text: text) }
  end

  def endpoint(*responses)
    stub_request(:post, "#{LLM_BASE}/chat/completions").to_return(*responses)
  end

  def answer
    TeamChat::Agent.new(@reply.reload, config: team_chat_config).run
  end

  test 'real agent retries a refused generation with a fresh budget and records physical attempts honestly' do
    timeouts = []
    config = team_chat_config
    original = config.method(:chat)
    config.define_singleton_method(:chat) do |**args|
      timeouts << args[:timeout]
      original.call(**args)
    end
    request = endpoint(refusal, success)
    TeamChat::Agent.new(@reply, config: config).run
    assert_requested request, times: 2
    assert_equal 'succeeded', @run.reload.state
    assert_equal 'Recovered answer', @reply.reload.body
    assert_operator timeouts.last, :<, timeouts.first
    assert_equal %w[failed succeeded], TeamChat::Telemetry.where(run_id: @run.id, kind: 'provider_attempt').order(:id).pluck(:outcome)
    summary = TeamChat::Telemetry.summary(@run)
    assert_equal 1, summary['generation_retry_reservations']
    assert_equal 0, summary['transport_retries']
    assert_operator summary['duration_ms']['retry_wait']['reported'], :>=, 0
    assert summary['duration_ms']['retry_wait']['complete']
    assert_nil summary['reported_cost_usd']
    assert_not summary['cost_complete']
    assert_not_includes TeamChat::Telemetry.where(run_id: @run.id).map(&:facts).to_json, 'private provider detail'
  end

  test 'repeated refusals exhaust one durable allowance rather than looping' do
    request = endpoint(refusal)
    answer
    assert_requested request, times: 2
    assert_equal 'failed', @run.reload.state
    assert_equal 1, TeamChat::Telemetry.where(run_id: @run.id, kind: 'generation_retry').count
  end

  test 'authorization billing and malformed requests never retry' do
    [400, 401, 402, 403].each do |status|
      WebMock.reset!
      @reply = TeamChat::Post.call(room: @room, user: @user, body: '@rupert explain my work').reply
      request = endpoint(refusal(status))
      answer
      assert_requested request, times: 1
      assert_equal 'failed', @reply.run.reload.state
      assert_equal 0, TeamChat::Telemetry.summary(@reply.run)['generation_retry_reservations']
    end
  end

  test 'rate limit retry after is respected and long or malformed hints are not retried' do
    request = endpoint(refusal(429, 'Retry-After' => '0'), success)
    answer
    assert_requested request, times: 2
    assert_equal 'succeeded', @run.reload.state
    assert_equal 0, TeamChat::Telemetry.find_by!(run_id: @run.id, kind: 'generation_retry').facts['delay_ms']
    ['120', 'invalid', '-1'].each do |hint|
      error = RubyLLM::RateLimitError.new(response: Faraday::Response.new(status: 429, response_headers: { 'retry-after' => hint }))
      assert_nil TeamChat::GenerationRetry.delay(error)
    end
    travel_to Time.current.change(usec: 0) do
      error = RubyLLM::ServiceUnavailableError.new(response: Faraday::Response.new(status: 503, response_headers: { 'retry-after' => 2.seconds.from_now.httpdate }))
      assert_equal 2, TeamChat::GenerationRetry.delay(error)
    end
  end

  test 'network timeouts with unknown provider processing are not retried' do
    request = stub_request(:post, "#{LLM_BASE}/chat/completions").to_timeout
    answer
    assert_requested request, times: 1
    assert_equal 'failed', @run.reload.state
    assert_equal 0, TeamChat::Telemetry.summary(@run)['generation_retry_reservations']
  end

  test 'a partial response is never replayed even if its later error looks transient' do
    request = endpoint(success)
    TeamChat::Execution.any_instance.stubs(:generate).yields(RubyLLM::Chunk.new(role: :assistant, content: 'Partial'))
      .raises(RubyLLM::ServiceUnavailableError.new(response: Faraday::Response.new(status: 503)))
    answer
    assert_not_requested request
    assert_equal 'failed', @run.reload.state
    assert_equal 0, TeamChat::Telemetry.summary(@run)['generation_retry_reservations']
  end

  test 'a completed tool round is not replayed when the following inference retries' do
    requests = []
    response = { status: 200, headers: { 'Content-Type' => 'text/event-stream' }, body: sse_for(tool: 'create_task', arguments: { title: 'One proposal' }) }
    stub_request(:post, "#{LLM_BASE}/chat/completions").with { |req| requests << JSON.parse(req.body) }.to_return(response, refusal, success)
    assert_difference -> { TeamChat::Approval.count }, 1 do
      assert_no_difference -> { Projects::Task.count } do
        answer
      end
    end
    assert_equal 'succeeded', @run.reload.state
    assert_equal 3, requests.size
    assert_equal requests[1], requests[2]
    assert_equal 1, @reply.reload.actions_list.size
    assert_equal 1, @run.tool_results.size
  end

  test 'a deadline with insufficient retry budget does not start a second request' do
    @run.update!(deadline_at: 5.seconds.from_now)
    request = endpoint(refusal(503, 'Retry-After' => '5'), success)
    answer
    assert_requested request, times: 1
    assert_equal 0, TeamChat::Telemetry.summary(@run)['generation_retry_reservations']
  end

  test 'cancellation during backoff prevents the retry request' do
    request = endpoint(refusal, success)
    TeamChat::Execution.any_instance.stubs(:wait_for_retry!).with do |_delay|
      @run.cancel!
      true
    end.returns(nil)
    answer
    assert_requested request, times: 1
    assert_equal 'cancelled', @run.reload.state
  end

  test 'revoked permissions after reservation prevent retry inference' do
    request = endpoint(refusal, success)
    TeamChat::Execution.any_instance.stubs(:wait_for_retry!).with do |_delay|
      @user.update_permission_overrides!(%w[settings.write dashboard.read])
      true
    end.returns(nil)
    answer
    assert_requested request, times: 1
    assert_equal 'cancelled', @run.reload.state
  end

  test 'the actual backoff loop observes stop and expiry before waiting again' do
    execution = TeamChat::Execution.new(@run, @run.claim!)
    execution.stubs(:sleep).with do |_delay|
      @run.cancel!
      true
    end
    assert_raises(TeamChat::Run::Stopped) { execution.wait_for_retry!(1) }
    assert_equal 'cancelled', @run.reload.state

    other = TeamChat::Post.call(room: @room, user: @user, body: '@rupert another question').reply.run
    execution = TeamChat::Execution.new(other, other.claim!)
    execution.stubs(:sleep).with do |_delay|
      other.update!(deadline_at: 1.second.ago)
      true
    end
    assert_raises(TeamChat::Run::Stopped) { execution.wait_for_retry!(1) }
    assert_equal 'expired', other.reload.state
  end

  test 'a superseded worker cannot reserve or wait through a successor claim' do
    execution = TeamChat::Execution.new(@run, @run.claim!)
    @run.update!(lease_until: 1.second.ago)
    successor = @run.claim!
    assert successor
    assert_raises(TeamChat::Run::Stopped) { execution.reserve_retry!(0, status: 503) }
    assert_raises(TeamChat::Run::Stopped) { execution.wait_for_retry!(0) }
    assert_equal successor, @run.reload.owner_token
    assert_equal 0, TeamChat::Telemetry.summary(@run)['generation_retry_reservations']
  end

  test 'local model cold starts keep their existing no retry policy' do
    request = endpoint(refusal, success)
    config = team_chat_config('RUPERT_CHAT_PROVIDER' => 'local_gateway', 'RUPERT_LOCAL_LLM_URL' => LLM_BASE)
    TeamChat::Agent.new(@reply, config: config).run
    assert_requested request, times: 1
    assert_equal 'failed', @run.reload.state
  end

  test 'recovery cannot replenish a reserved retry allowance' do
    request = endpoint(refusal, success)
    TeamChat::Execution.any_instance.stubs(:wait_for_retry!).raises(TeamChat::Run::Stopped)
    answer
    assert_equal 'running', @run.reload.state
    assert_equal 1, TeamChat::Telemetry.summary(@run)['generation_retry_reservations']
    @run.update!(lease_until: 1.second.ago)
    TeamChat::Execution.any_instance.unstub(:wait_for_retry!)
    # On recovery another refusal must fail, not consume the synthetic success.
    WebMock.reset!
    request = endpoint(refusal, success)
    answer
    assert_requested request, times: 1
    assert_equal 'failed', @run.reload.state
    assert_equal 1, TeamChat::Telemetry.summary(@run)['generation_retry_reservations']
  end
end
