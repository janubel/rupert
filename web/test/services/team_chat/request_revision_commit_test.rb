# frozen_string_literal: true

require 'test_helper'
require_relative '../../support/team_chat_helper'
require 'timeout'

class TeamChatRequestRevisionCommitTest < ActiveSupport::TestCase
  include TeamChatHelper
  include ActiveJob::TestHelper
  self.use_transactional_tests = false

  setup do
    Current.tenant = @tenant = tenants(:default_tenant)
    Current.user = @user = users(:regular_user)
    @room = TeamChat::Room.create!(name: 'Revision verification', slug: "revision-#{SecureRandom.hex(5)}", kind: 'direct', created_by: @user, assistant_mode: 'mentions')
    post = TeamChat::Post.call(room: @room, user: @user, body: '@rupert explain the original workflow')
    @trigger, @reply = post.message, post.reply
    clear_enqueued_jobs
  end

  teardown do
    Current.tenant = @tenant
    @room&.destroy!
    AiAgentRun.where(model: 'test-model', agent: 'team_chat').delete_all
    clear_enqueued_jobs
    Current.reset
  end

  test 'the replacement is enqueued once only after its outer transaction commits' do
    replacement = nil
    TeamChat::Message.transaction do
      @trigger.edit_body!('@rupert where is inventory?')
      replacement = @trigger.revision_updates.select(&:pending?).last
      assert_enqueued_jobs 0, only: TeamChat::ReplyJob
    end
    assert_enqueued_with(job: TeamChat::ReplyJob, args: [replacement.id])
    assert_enqueued_jobs 1, only: TeamChat::ReplyJob
    assert_equal 'cancelled', @reply.run.reload.state
  end

  test 'rollback restores the original request and does not enqueue a replacement' do
    body = @trigger.body
    TeamChat::Message.transaction do
      @trigger.edit_body!('@rupert where is inventory?')
      raise ActiveRecord::Rollback
    end
    assert_enqueued_jobs 0, only: TeamChat::ReplyJob
    assert_equal body, @trigger.reload.body
    assert_equal 0, @trigger.request_revision
    assert_equal 'queued', @reply.run.reload.state
    assert_equal 1, @room.messages.where(author_kind: 'assistant').count
  end

  test 'recovery dispatches a committed replacement if its enqueue was lost' do
    @trigger.edit_body!('@rupert where is inventory?')
    replacement = @trigger.revision_updates.select(&:pending?).last
    clear_enqueued_jobs
    TeamChat::RecoverRunsJob.perform_now
    assert_enqueued_with(job: TeamChat::ReplyJob, args: [replacement.id])
    assert_enqueued_jobs 1, only: TeamChat::ReplyJob
    Current.tenant = @tenant
    Current.user = @user
    TeamChat::Agent.new(@reply.reload, config: team_chat_config).run
    TeamChat::Agent.new(replacement.reload, config: team_chat_config).run
    assert_equal 'succeeded', replacement.run.reload.state
    assert_includes replacement.reload.body, '](/inventory)'
    assert_equal 'cancelled', @reply.run.reload.state
  end

  test 'editing releases silent inference without waiting for the provider timeout' do
    entered, released = Queue.new, Queue.new
    request = stub_request(:post, "#{LLM_BASE}/chat/completions").to_return do
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
    @trigger.edit_body!('@rupert where is inventory?')
    replacement = @trigger.revision_updates.select(&:pending?).last
    assert actor.join(3), 'edited requests must release the inference worker'
    assert Timeout.timeout(3) { released.pop }
    assert_equal 'cancelled', @reply.run.reload.state
    TeamChat::Agent.new(replacement.reload, config: team_chat_config).run
    assert_equal 'succeeded', replacement.run.reload.state
    assert_requested request, times: 1
  ensure
    actor&.kill if actor&.alive?
    actor&.join
  end

  test 'SIGKILL followed by a request edit cannot recover the old transcript' do
    reader, writer = IO.pipe
    stub_request(:post, "#{LLM_BASE}/chat/completions").to_return do
      writer.write('generating')
      writer.flush
      Process.kill('KILL', Process.pid)
    end
    ActiveRecord::Base.connection_handler.clear_all_connections!
    child = fork do
      reader.close
      ActiveRecord::Base.establish_connection
      TeamChat::Agent.new(TeamChat::Message.find(@reply.id), config: team_chat_config).run
      exit! 2
    end
    writer.close
    assert_equal 'generating', Timeout.timeout(10) { reader.read }
    _, status = Process.waitpid2(child)
    child = nil
    assert_equal Signal.list.fetch('KILL'), status.termsig
    original = @reply.run.reload.request_context.deep_dup
    assert_equal 'running', @reply.run.state
    @trigger.edit_body!('@rupert where is inventory?')
    replacement = @trigger.revision_updates.select(&:pending?).last
    WebMock.reset!
    TeamChat::Agent.new(@reply.reload, config: team_chat_config).run
    TeamChat::Agent.new(replacement.reload, config: team_chat_config).run
    assert_equal original, @reply.run.reload.request_context
    assert_equal 'cancelled', @reply.run.state
    assert_equal 'succeeded', replacement.run.reload.state
    assert_includes replacement.reload.body, '](/inventory)'
    assert_not_requested :post, "#{LLM_BASE}/chat/completions"
  ensure
    Process.kill('KILL', child) if child
    Process.waitpid(child) if child
    reader&.close unless reader&.closed?
    writer&.close unless writer&.closed?
  end
end
