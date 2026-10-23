# frozen_string_literal: true

require 'test_helper'
require_relative '../../support/team_chat_helper'
require 'timeout'

class TeamChatRestartTest < ActiveSupport::TestCase
  include TeamChatHelper
  self.use_transactional_tests = false

  setup do
    @tenant = tenants(:default_tenant)
    @user = users(:regular_user)
    Current.tenant = @tenant
    Current.user = @user
    @room = TeamChat::Room.create!(name: 'Restart verification', slug: "restart-#{SecureRandom.hex(5)}", kind: 'direct', created_by: @user, assistant_mode: 'mentions')
    @reply = TeamChat::Post.call(room: @room, user: @user, body: '@rupert make a task').reply
  end

  teardown do
    Current.tenant = @tenant
    @room&.destroy!
    AiAgentRun.where(model: 'test-model', agent: 'team_chat').delete_all
    Current.reset
  end

  test 'atomic claims admit exactly one concurrent owner' do
    gate = Queue.new
    results = Queue.new
    threads = 2.times.map do
      Thread.new do
        gate.pop
        ActiveRecord::Base.connection_pool.with_connection do
          results << TeamChat::Run.unscoped.find_by!(message_id: @reply.id).claim!
        end
      end
    end
    2.times { gate << true }
    threads.each(&:join)
    assert_equal 1, 2.times.map { results.pop }.compact.size
    assert_equal 1, @reply.run.reload.attempts
    assert_equal 1, TeamChat::Telemetry.where(run_id: @reply.run.id, kind: 'claim').count
  end

  test 'heartbeat keeps a slow live worker lease fresh and stops after release' do
    run = @reply.run
    context = TeamChat::Execution.new(run, run.claim!)
    run.update!(lease_until: 10.seconds.from_now)
    before = run.lease_until
    context.start_watch
    Timeout.timeout(8) do
      sleep 0.05 until run.reload.lease_until > before
    end
    assert_nil TeamChat::Run.unscoped.find(run.id).claim!
    run.cancel!
    context.stop_watch
    assert_equal 'cancelled', run.reload.state
  ensure
    context&.stop_watch
  end

  test 'cancelling silent model I/O releases execution without waiting for HTTP timeout' do
    entered = Queue.new
    released = Queue.new
    stub_request(:post, "#{LLM_BASE}/chat/completions").to_return do
      entered << true
      begin
        Queue.new.pop
      ensure
        released << true
      end
    end
    actor = Thread.new do
      Current.tenant = @tenant
      Current.user = @user
      TeamChat::Agent.new(TeamChat::Message.find(@reply.id), config: team_chat_config).run
    ensure
      Current.reset
    end
    Timeout.timeout(5) { entered.pop }
    @reply.run.cancel!
    assert actor.join(3), 'silent inference must not retain the chat worker'
    assert Timeout.timeout(3) { released.pop }
    assert_equal 'cancelled', @reply.run.reload.state
    assert_not TeamChat::Telemetry.where(run_id: @reply.run.id, outcome: 'running').exists?
  ensure
    actor&.kill if actor&.alive?
    actor&.join
  end

  test 'SIGKILL after reserving a retry cannot replenish the allowance on recovery' do
    reader, writer = IO.pipe
    request = stub_request(:post, "#{LLM_BASE}/chat/completions").to_return(status: 503, body: '{"error":{"message":"temporary refusal"}}')
    ActiveRecord::Base.connection_handler.clear_all_connections!
    child = fork do
      reader.close
      ActiveRecord::Base.establish_connection
      TeamChat::Execution.define_method(:wait_for_retry!) do |_delay|
        writer.write('reserved')
        writer.flush
        Process.kill('KILL', Process.pid)
      end
      TeamChat::Agent.new(TeamChat::Message.find(@reply.id), config: team_chat_config).run
      exit! 2
    end
    writer.close
    assert_equal 'reserved', Timeout.timeout(10) { reader.read }
    _, status = Process.waitpid2(child)
    child = nil
    assert_equal Signal.list.fetch('KILL'), status.termsig
    run = TeamChat::Run.unscoped.find_by!(message_id: @reply.id)
    assert_equal 'running', run.state
    assert_equal 1, TeamChat::Telemetry.summary(run)['generation_retry_reservations']
    run.update!(lease_until: 1.second.ago)
    TeamChat::Agent.new(@reply.reload, config: team_chat_config).run
    assert_requested request, times: 1 # Child requests are in a separate process.
    assert_equal 'failed', run.reload.state
    assert_equal 2, run.attempts
    assert_equal 1, TeamChat::Telemetry.summary(run)['generation_retry_reservations']
    assert_equal 2, TeamChat::Telemetry.where(run_id: run.id, kind: 'provider_attempt').count
  ensure
    Process.kill('KILL', child) if child
    Process.waitpid(child) if child
    reader&.close unless reader&.closed?
    writer&.close unless writer&.closed?
  end

  test 'SIGKILL after tool checkpoint recovers in a new process without another proposal' do
    reader, writer = IO.pipe
    stub_request(:post, "#{LLM_BASE}/chat/completions").to_return do |request|
      parsed = JSON.parse(request.body)
      if parsed['messages'].last['role'] == 'tool'
        writer.write('checkpointed')
        writer.flush
        Process.kill('KILL', Process.pid)
      end
      { status: 200, headers: { 'Content-Type' => 'text/event-stream' }, body: sse_for(tool: 'create_task', arguments: { title: 'One restart proposal' }) }
    end
    ActiveRecord::Base.connection_handler.clear_all_connections!
    child = fork do
      reader.close
      ActiveRecord::Base.establish_connection
      TeamChat::Agent.new(TeamChat::Message.find(@reply.id), config: team_chat_config).run
      exit! 2
    end
    writer.close
    assert_equal 'checkpointed', Timeout.timeout(10) { reader.read }
    _, status = Process.waitpid2(child)
    child = nil
    assert_equal Signal.list.fetch('KILL'), status.termsig
    run = TeamChat::Run.unscoped.find_by!(message_id: @reply.id)
    assert_equal 'running', run.state
    assert_equal 'tool', run.transcript.last['role']
    run.update!(lease_until: 1.second.ago)
    requests = script_model(text: 'Waiting for approval.')
    TeamChat::Agent.new(@reply.reload, config: team_chat_config).run
    assert_equal 'succeeded', run.reload.state
    assert_equal 2, run.attempts
    assert_equal 1, @reply.reload.actions_list.size
    assert_equal 1, requests.size
    ledger = TeamChat::Telemetry.where(run_id: run.id)
    assert_equal 2, ledger.where(kind: 'claim').count
    assert_equal 1, ledger.where(kind: 'tool').count
    assert_equal 2, ledger.where(kind: 'provider_attempt').count
    assert ledger.where(kind: 'inference', outcome: 'interrupted', duration_ms: nil).exists?
    assert_not TeamChat::Telemetry.summary(run)['tokens']['input_tokens']['complete']
  ensure
    Process.kill('KILL', child) if child
    Process.waitpid(child) if child
    reader&.close unless reader&.closed?
    writer&.close unless writer&.closed?
  end
end
