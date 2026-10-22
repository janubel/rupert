# frozen_string_literal: true

require 'test_helper'
require_relative '../../support/team_chat_helper'

class TeamChatRunTest < ActiveSupport::TestCase
  include TeamChatHelper
  include ActiveJob::TestHelper
  Crash = Class.new(Exception)

  setup do
    Current.tenant = tenants(:default_tenant)
    @user = users(:regular_user)
    Current.user = @user
    @room = TeamChat::Room.ensure_defaults!(@user)
    @reply = TeamChat::Post.call(room: @room, user: @user, body: '@rupert make a task').reply
    @run = @reply.run
    TeamChat::Execution.any_instance.stubs(:start_watch)
  end
  teardown { Current.reset }

  def execution
    TeamChat::Execution.new(@run, @run.claim!)
  end

  test 'a second delivery cannot claim an active run or extend its deadline' do
    token = @run.claim!
    deadline = @run.deadline_at
    assert token
    assert_nil TeamChat::Run.find(@run.id).claim!
    assert_equal 1, @run.reload.attempts
    assert_equal deadline, @run.deadline_at
    assert_equal @run.id, TeamChat::Run.for_reply!(@reply).id
  end

  test 'reclaimed runs reject all writes and tool starts from the old owner' do
    old = execution
    @run.update!(lease_until: 1.second.ago)
    current = execution
    assert current.token
    assert_not_equal old.token, current.token
    assert_raises(TeamChat::Run::Stopped) { old.write_reply!({ body: 'late answer' }, terminal: 'succeeded') }
    assert_raises(TeamChat::Run::Stopped) { old.tool!('x', 'where_is', {}) { flunk 'old tool ran' } }
    current.write_reply!({ body: 'current', status: 'done' }, terminal: 'succeeded')
    assert_equal 'current', @reply.reload.body
  end

  test 'cancellation is terminal and dismisses only unapproved proposals' do
    context = execution
    first = TeamChat::Actions.propose!(@reply, tool: 'create_task', arguments: { 'title' => 'Approved once' }, proposed_for: @user)
    TeamChat::Actions.decide!(@reply, first['id'], user: @user, approve: true)
    TeamChat::Actions.propose!(@reply, tool: 'create_task', arguments: { 'title' => 'Never approve' }, proposed_for: @user)
    @run.cancel!
    assert_equal %w[done dismissed], @reply.reload.actions_list.pluck('status')
    assert_equal 'cancelled', @run.reload.state
    assert_raises(TeamChat::Run::Stopped) { context.write_reply!({ body: 'late completion' }, terminal: 'succeeded') }
    assert_equal 'Stopped.', @reply.reload.body
    assert_nil @run.claim!
  end

  test 'a whole run deadline prevents claims and expires queued work' do
    @run.update!(deadline_at: 1.second.ago)
    assert_nil @run.claim!
    assert_equal 'expired', @run.reload.state
    assert_equal 'failed', @reply.reload.status
    assert_no_enqueued_jobs(only: TeamChat::ReplyJob) { TeamChat::RecoverRunsJob.perform_now }
  end

  test 'recovery re-enqueues expired leases but never steals a fresh lease or renews the deadline' do
    context = execution
    deadline = @run.deadline_at
    assert_no_enqueued_jobs(only: TeamChat::ReplyJob) { TeamChat::RecoverRunsJob.perform_now }
    @run.update!(lease_until: 1.second.ago)
    assert_enqueued_with(job: TeamChat::ReplyJob, args: [@reply.id]) { TeamChat::RecoverRunsJob.perform_now }
    assert_no_enqueued_jobs(only: TeamChat::ReplyJob) { TeamChat::RecoverRunsJob.perform_now }
    assert_equal deadline, @run.reload.deadline_at
    assert context.token
  end

  test 'recovery terminates an exhausted abandoned run without another delivery' do
    execution
    @run.update!(attempts: TeamChat::Run::MAX_ATTEMPTS, lease_until: 1.second.ago)
    assert_no_enqueued_jobs(only: TeamChat::ReplyJob) { TeamChat::RecoverRunsJob.perform_now }
    assert_equal 'failed', @run.reload.state
    assert_equal 'failed', @reply.reload.status
    assert_nil @run.claim!
  end

  test 'a lost initial enqueue is recovered without browser polling' do
    assert_enqueued_with(job: TeamChat::ReplyJob, args: [@reply.id]) { TeamChat::RecoverRunsJob.perform_now }
    assert_no_enqueued_jobs(only: TeamChat::ReplyJob) { TeamChat::RecoverRunsJob.perform_now }
  end

  test 'proposal and replay receipt commit together and prevent duplicates after restart' do
    context = execution
    toolbox = TeamChat::Toolbox.new(user: @user, room: @room, reply: @reply, execution: context)
    toolbox.call_id = 'call-task'
    first = toolbox.call('create_task', { 'title' => 'One proposal' })
    @run.update!(lease_until: 1.second.ago)
    recovered = execution
    second_box = TeamChat::Toolbox.new(user: @user, room: @room, reply: @reply.reload, execution: recovered)
    second_box.call_id = 'call-task'
    assert_equal first, second_box.call('create_task', { 'title' => 'One proposal' })
    assert_equal 1, @reply.reload.actions_list.size
    assert_equal 1, @run.reload.tool_results.size
    assert_equal 1, second_box.calls
  end

  test 'an interrupted native run resumes its private transcript and does not repeat proposals' do
    tool = sse_for(tool: 'create_task', arguments: { title: 'Only one card' })
    calls = 0
    stub_request(:post, "#{LLM_BASE}/chat/completions").to_return do
      calls += 1
      raise Crash, 'worker killed after tool checkpoint' if calls == 2

      { status: 200, headers: { 'Content-Type' => 'text/event-stream' }, body: tool }
    end
    assert_raises(Crash) { TeamChat::Agent.new(@reply, config: team_chat_config).run }
    assert_equal 1, @reply.reload.actions_list.size
    assert_equal 'running', @run.reload.state
    assert_equal 'tool', @run.transcript.last['role']
    @run.update!(lease_until: 1.second.ago)
    requests = script_model(text: 'The task is waiting for approval.')
    TeamChat::Agent.new(@reply.reload, config: team_chat_config).run
    assert_equal 'succeeded', @run.reload.state
    assert_equal 2, @run.attempts
    assert_equal 1, @reply.reload.actions_list.size
    assert requests.first['messages'].any? { |message| message['role'] == 'tool' }
  end

  test 'CLI recovery resumes the saved tool round without repeating its proposal' do
    config = team_chat_config
    config.stubs(:native?).returns(false)
    provider = AskRupert::Providers::Opencode.any_instance
    call = AskRupert::Providers::Reply.new(text: 'TOOL_CALL: {"name":"create_task","arguments":{"title":"CLI once"}}', tokens_in: 0, tokens_out: 0)
    provider.stubs(:complete).returns(call).then.raises(Crash)
    assert_raises(Crash) { TeamChat::Agent.new(@reply, config: config).run }
    assert_equal 1, @run.reload.steps
    assert_equal 1, @reply.reload.actions_list.size
    @run.update!(lease_until: 1.second.ago)
    provider.stubs(:complete).returns(AskRupert::Providers::Reply.new(text: 'Waiting for approval.', tokens_in: 0, tokens_out: 0))
    TeamChat::Agent.new(@reply, config: config).run
    assert_equal 'succeeded', @run.reload.state
    assert_equal 1, @reply.reload.actions_list.size
  end

  test 'cancellation during streaming cannot publish a final answer or start tools' do
    script_model(text: 'A streamed answer that should stop.')
    TeamChat::Agent.any_instance.stubs(:publish).with do |_text|
      @run.cancel!
      true
    end
    TeamChat::Agent.new(@reply, config: team_chat_config).run
    assert_equal 'cancelled', @run.reload.state
    assert_equal 'Stopped.', @reply.reload.body
    assert_empty @run.tool_results
  end

  test 'a crash between a proposal and its replay receipt rolls both back' do
    context = execution
    assert_raises(Crash) do
      context.tool!('atomic', 'create_task', { 'title' => 'Atomic' }, write: true) do
        TeamChat::Actions.propose!(@reply, tool: 'create_task', arguments: { 'title' => 'Atomic' }, proposed_for: @user)
        raise Crash
      end
    end
    assert_empty @reply.reload.actions_list
    assert_empty @run.reload.tool_results
  end

  test 'deadline expiry during a response prevents finalization and dismisses pending cards' do
    TeamChat::Actions.propose!(@reply, tool: 'create_task', arguments: { 'title' => 'Expired' }, proposed_for: @user)
    stub_request(:post, "#{LLM_BASE}/chat/completions").to_return do
      @run.update!(deadline_at: 1.second.ago)
      { status: 200, headers: { 'Content-Type' => 'text/event-stream' }, body: sse_for(text: 'Late answer') }
    end
    TeamChat::Agent.new(@reply, config: team_chat_config).run
    assert_equal 'expired', @run.reload.state
    assert_equal 'failed', @reply.reload.status
    assert_equal ['dismissed'], @reply.actions_list.pluck('status')
    assert_not_includes @reply.body, 'Late answer'
  end

  test 'completed model and tool steps keep their cumulative step budget on recovery' do
    @run.update!(steps: TeamChat::Agent::MAX_STEPS)
    script_model(text: 'Should not generate')
    TeamChat::Agent.new(@reply, config: team_chat_config).run
    assert_equal 'failed', @run.reload.state
    assert_not_requested :post, "#{LLM_BASE}/chat/completions"
  end
end
