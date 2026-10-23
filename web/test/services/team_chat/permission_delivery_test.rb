# frozen_string_literal: true

require 'test_helper'
require_relative '../../support/team_chat_helper'

class TeamChatPermissionDeliveryTest < ActiveSupport::TestCase
  include TeamChatHelper
  include ActiveJob::TestHelper

  setup do
    Current.tenant = tenants(:default_tenant)
    @user = users(:regular_user)
    Current.user = @user
    @room = TeamChat::Room.direct_for(@user)
    TeamChat::Execution.any_instance.stubs(:start_watch)
  end
  teardown { Current.reset }

  def reply(room = @room)
    TeamChat::Post.call(room: room, user: @user, body: '@rupert show our sales').reply
  end

  def execution(message)
    run = message.run
    TeamChat::Execution.new(run, run.claim!)
  end

  def revoke_sales
    @user.update_permission_overrides!(%w[settings.write dashboard.read])
  end

  test 'mixed-permission channel receives only a private handoff, without inference or shared history' do
    channel = TeamChat::Room.ensure_defaults!(@user)
    viewer = User.create!(tenant: Current.tenant, email: 'limited-chat@example.com', name: 'Limited', role: 'reader', password: 'password123')
    viewer.update_permission_overrides!(%w[settings.write dashboard.read])
    assert TeamChat.allowed?(viewer)
    assert_not viewer.can?('sales.read')
    assert channel.visible_to?(viewer)
    channel.messages.create!(author_kind: 'person', user: @user, body: 'Earlier confidential channel context')
    message = reply(channel)
    TeamChat::Agent.any_instance.expects(:answer).never
    assert_enqueued_jobs 1, only: TeamChat::ReplyJob do
      TeamChat::Agent.new(message, config: team_chat_config).run
    end
    assert_equal 'succeeded', message.run.reload.state
    assert_match(/private Rupert room/, message.reload.body)
    private_reply = @room.messages.where(author_kind: 'assistant').last
    assert_equal channel.id, private_reply.run.request_context['source_room_id']
    assert_equal ['@rupert show our sales'], TeamChat::Agent.new(private_reply).transcript.map { |entry| entry[:content].sub(/\A[^:]+: /, '') }
    assert_equal @user.id, private_reply.run.request_context['requester_id']
    assert_not @room.visible_to?(viewer)
    assert_equal ['@rupert show our sales'], @room.messages.where(author_kind: 'person').pluck(:body)
    # A retry cannot enqueue or copy the request again.
    assert_no_difference 'TeamChat::Message.count' do
      TeamChat::Agent.new(message, config: team_chat_config).run
    end
  end

  test 'a shared direct message also hands off without using the other persons conversation' do
    other = User.create!(tenant: Current.tenant, email: 'dm-peer@example.com', name: 'Peer', role: 'admin', password: 'password123')
    room = TeamChat::Room.dm_between(@user, other)
    message = reply(room)
    TeamChat::Agent.any_instance.expects(:answer).never
    TeamChat::Agent.new(message, config: team_chat_config).run
    assert_equal 'done', message.reload.status
    assert_not @room.visible_to?(other)
    assert_equal 1, @room.messages.where(author_kind: 'assistant').count
  end

  test 'legacy runs without an access snapshot fail closed before model recovery' do
    message = reply
    TeamChat::Run.where(id: message.run.id).update_all(request_context: message.run.request_context.except('permissions_signature'))
    TeamChat::Agent.any_instance.expects(:answer).never
    TeamChat::Agent.new(message, config: team_chat_config).run
    assert_equal 'cancelled', message.run.reload.state
  end

  test 'revocation before a tool prevents execution even with memoized permissions' do
    message = reply
    context = execution(message)
    assert @user.can?('sales.read')
    revoke_sales
    assert_raises(TeamChat::Run::Stopped) { context.tool!('sales', 'sales_summary', {}) { flunk 'tool executed' } }
    assert_equal 'cancelled', message.run.reload.state
  end

  test 'revocation during inference rejects streamed and final writes and clears partial data' do
    message = reply
    context = execution(message)
    context.write_reply!({ body: 'Partial private result' })
    revoke_sales
    assert_raises(TeamChat::Run::Stopped) { context.write_reply!({ body: 'Secret sales', status: 'done' }, terminal: 'succeeded') }
    assert_equal 'cancelled', message.run.reload.state
    assert_not_includes message.reload.body, 'Partial'
    assert_not_includes message.body, 'Secret'
  end

  test 'the generation loop observes revoked access between streamed chunks' do
    message = reply
    context = execution(message)
    chat = Object.new
    chat.define_singleton_method(:generate) do |&emit|
      emit.call('first')
      sleep 0.3
      emit.call('late secret')
    end
    chat.define_singleton_method(:cancel) { nil }
    seen = []
    assert_raises(TeamChat::Run::Stopped) do
      context.generate(chat) do |chunk|
        seen << chunk
        @user.update!(active: false)
      end
    end
    assert_equal ['first'], seen
    assert_equal 'cancelled', message.run.reload.state
  end

  test 'recovery after permission revocation cannot replay saved tool results or call the model' do
    message = reply
    context = execution(message)
    context.tool!('sales', 'sales_summary', {}) { 'Saved confidential sales' }
    message.run.update!(lease_until: 1.second.ago)
    revoke_sales
    TeamChat::Agent.any_instance.expects(:answer).never
    TeamChat::Agent.new(message, config: team_chat_config).run
    assert_equal 'cancelled', message.run.reload.state
    assert_not_includes message.reload.body, 'confidential'
  end

  test 'a tool result obtained during revocation is discarded instead of checkpointed' do
    message = reply
    context = execution(message)
    assert_raises(TeamChat::Run::Stopped) do
      context.tool!('sales', 'sales_summary', {}) do
        revoke_sales
        'Confidential result returned after revocation'
      end
    end
    assert_empty message.run.reload.tool_results
    assert_equal 'cancelled', message.run.state
  end

  test 'recovery after a private handoff stops when the source room is archived' do
    channel = TeamChat::Room.ensure_defaults!(@user)
    source_reply = reply(channel)
    TeamChat::Agent.new(source_reply, config: team_chat_config).run
    private_reply = @room.messages.where(author_kind: 'assistant').last
    channel.update!(archived_at: Time.current)
    TeamChat::Agent.any_instance.expects(:answer).never
    TeamChat::Agent.new(private_reply, config: team_chat_config).run
    assert_equal 'cancelled', private_reply.run.reload.state
  end

  test 'archiving the room prevents tools and publication' do
    message = reply
    context = execution(message)
    @room.update!(archived_at: Time.current)
    assert_raises(TeamChat::Run::Stopped) { context.tool!('x', 'where_is', {}) { flunk 'tool executed' } }
  end

  test 'deactivation invalidates execution' do
    message = reply
    context = execution(message)
    @user.update!(active: false)
    assert_raises(TeamChat::Run::Stopped) { context.check! }
  end

  test 'permission checks reject cross-tenant execution context' do
    message = reply
    context = execution(message)
    Current.tenant = nil
    assert_raises(TeamChat::Run::Stopped) { context.check! }
  end
end
