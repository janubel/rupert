# frozen_string_literal: true

require 'test_helper'
require_relative '../../support/team_chat_helper'

class TeamChatRequestRevisionTest < ActiveSupport::TestCase
  include TeamChatHelper

  setup do
    Current.tenant = tenants(:default_tenant)
    Current.user = @user = users(:regular_user)
    @room = TeamChat::Room.direct_for(@user)
    @room.update!(assistant_mode: 'mentions')
    @post = TeamChat::Post.call(room: @room, user: @user, body: '@rupert create a task called Original')
    @trigger, @reply = @post.message, @post.reply
    @run = @reply.run
    TeamChat::Execution.any_instance.stubs(:start_watch)
  end
  teardown { Current.reset }

  def edit(text = '@rupert create a task called Revised')
    @trigger.edit_body!(text)
    @trigger.revision_updates.select(&:pending?).last
  end

  def execute(reply = @reply)
    TeamChat::Agent.new(reply.reload, config: team_chat_config).run
  end

  test 'editing queued work creates a new snapshot on the same human message and stops the old run' do
    snapshot = @run.request_context.deep_dup
    replacement = nil
    assert_no_difference -> { @room.messages.where(author_kind: 'person').count } do
      assert_difference -> { TeamChat::Run.count }, 1 do
        replacement = edit
      end
    end
    assert_equal 'cancelled', @run.reload.state
    assert_equal snapshot, @run.request_context
    assert_equal 1, @trigger.reload.request_revision
    assert_equal @trigger.id, replacement.run.request_context['trigger_id']
    assert_equal 1, replacement.run.request_context['request_revision']
    assert_equal @trigger.body, replacement.run.request_context['last_chat']
    assert_equal @trigger.edited_at.iso8601(6), replacement.run.request_context['requested_at']
    script_model({ tool: 'create_task', arguments: { title: 'Revised' } }, { text: 'Waiting for approval.' })
    execute(@reply)
    execute(replacement)
    assert_equal 'succeeded', replacement.run.reload.state
    approval = TeamChat::Approval.find_by!(message_id: replacement.id)
    assert_equal @trigger.body, approval.provenance['last_chat']
    assert_equal 1, approval.provenance['request_revision']
    assert_equal 1, TeamChat::Approval.where(message_id: [@reply.id, replacement.id]).count
  end

  test 'deleting a queued direct navigation request produces no answer or replacement' do
    post = TeamChat::Post.call(room: @room, user: @user, body: '@rupert where are timesheets?')
    assert_no_difference -> { TeamChat::Run.count } do
      post.message.soft_delete!
    end
    execute(post.reply)
    assert_equal 'cancelled', post.reply.run.reload.state
    assert_not_includes post.reply.reload.body, '](/people/timesheets)'
    assert_not_requested :post, "#{LLM_BASE}/chat/completions"
  end

  test 'raw changes are fenced before inference and after lookup even without the normal edit hook' do
    @trigger.update_columns(body: 'changed outside the editor')
    execute
    assert_equal 'cancelled', @run.reload.state
    assert_not_requested :post, "#{LLM_BASE}/chat/completions"

    post = TeamChat::Post.call(room: @room, user: @user, body: '@rupert where are timesheets?')
    lookup = AskRupert::Tools.instance_method(:call)
    # Wrap the real lookup, mutating the source only after it has returned.
    AskRupert::Tools.define_method(:call) do |*args|
      result = lookup.bind_call(self, *args)
      post.message.update_columns(body: 'changed during lookup')
      result
    end
    execute(post.reply)
    assert_equal 'cancelled', post.reply.run.reload.state
    assert_not_includes post.reply.reload.body, '](/people/timesheets)'
  ensure
    AskRupert::Tools.define_method(:call, lookup) if lookup
  end

  test 'timestamp checks fence external edits that leave the revision counter unchanged' do
    [true, false].each do |legacy|
      post = TeamChat::Post.call(room: @room, user: @user, body: '@rupert explain the original workflow')
      run = post.reply.run
      TeamChat::Run.where(id: run.id).update_all(request_context: run.request_context.except('request_revision')) if legacy
      post.message.update_columns(edited_at: 1.second.from_now)
      execute(post.reply)
      assert_equal 'cancelled', run.reload.state
    end
    assert_not_requested :post, "#{LLM_BASE}/chat/completions"
  end

  test 'a stale claimant cannot checkpoint or publish after an edit' do
    execution = TeamChat::Execution.new(@run, @run.claim!)
    replacement = edit
    assert_raises(TeamChat::Run::Stopped) { execution.write_reply!({ body: 'obsolete answer' }) }
    assert_equal 'cancelled', @run.reload.state
    assert_equal 'queued', replacement.run.reload.state
    assert_not_includes @reply.reload.body, 'obsolete answer'
  end

  test 'recovery cannot replay a transcript or tool result for a changed request' do
    @run.claim!
    @run.update!(transcript: [{ role: 'user', content: 'Original' }], tool_results: [{ 'id' => 'old-call' }], lease_until: 1.second.ago)
    @trigger.update_columns(body: 'changed while worker was down')
    execute
    assert_equal 'cancelled', @run.reload.state
    assert_not_requested :post, "#{LLM_BASE}/chat/completions"
  end

  test 'the request guard persists cancellation after a guarded transaction rolls back' do
    execution = TeamChat::Execution.new(@run, @run.claim!)
    @trigger.update_columns(body: 'raw changed body')
    assert_raises(TeamChat::Execution::RequestChanged) { execution.write_reply!({ body: 'wrong answer' }) }
    assert_equal 'cancelled', @run.reload.state
    assert_not_includes @reply.reload.body, 'wrong answer'
  end

  test 'pending approval cards are dismissed but completed receipts and effects remain immutable' do
    pending = TeamChat::Actions.propose!(@reply, tool: 'create_task', arguments: { 'title' => 'Old proposal' }, proposed_for: @user)
    decided = TeamChat::Actions.propose!(@reply, tool: 'create_task', arguments: { 'title' => 'Completed original' }, proposed_for: @user)
    receipt = TeamChat::Actions.decide!(@reply, decided['id'], user: @user, approve: true)
    record = TeamChat::Approval.find_by!(public_id: decided['id'])
    provenance = record.provenance.deep_dup
    assert_no_difference -> { Projects::Task.count } do
      edit
    end
    assert_equal receipt, record.reload.receipt
    assert_equal receipt, TeamChat::Actions.decide!(@reply, decided['id'], user: @user, approve: true)
    assert_equal provenance, record.provenance
    assert_equal 'done', record.state
    assert_equal 'dismissed', TeamChat::Approval.find_by!(public_id: pending['id']).state
    assert_raises(TeamChat::Actions::Denied) { TeamChat::Actions.decide!(@reply, pending['id'], user: @user, approve: true) }
  end

  test 'replacement context warns about executed changes without replaying their private results' do
    card = TeamChat::Actions.propose!(@reply, tool: 'create_task', arguments: { 'title' => 'Previous private task title' }, proposed_for: @user)
    TeamChat::Actions.decide!(@reply, card['id'], user: @user, approve: true)
    edit
    replacement = edit('@rupert create a task called Revised again')
    requests = script_model(text: 'Checking the current state.')
    execute(replacement)
    context = requests.first['messages'].last['content']
    assert_includes context, 'previous version of this request already had an approved change executed'
    assert_not_includes context, 'Previous private task title'
    assert_equal [@reply.id], replacement.run.request_context['prior_reply_ids']
  end

  test 'editing or deleting a request awaiting approval retracts the card without rewriting its completed answer' do
    script_model({ tool: 'create_task', arguments: { title: 'Original pending review' } }, { text: 'Waiting for approval.' })
    execute
    card = @reply.reload.actions_list.first
    answer = @reply.body
    replacement = edit
    assert replacement.pending?
    assert_equal 'succeeded', @run.reload.state
    assert_equal answer, @reply.reload.body
    assert_equal 'dismissed', @reply.actions_list.first['status']
    assert_raises(TeamChat::Actions::Denied) { TeamChat::Actions.decide!(@reply, card['id'], user: @user, approve: true) }
    @trigger.soft_delete!
    assert_equal 'cancelled', replacement.run.reload.state
  end

  test 'pending proposals without a durable request cannot execute' do
    legacy = @room.messages.create!(author_kind: 'assistant', status: 'done')
    card = TeamChat::Actions.propose!(legacy, tool: 'create_task', arguments: { 'title' => 'Unknown original request' }, proposed_for: @user)
    assert_no_difference -> { Projects::Task.count } do
      assert_raises(TeamChat::Actions::Denied) { TeamChat::Actions.decide!(legacy, card['id'], user: @user, approve: true) }
    end
  end

  test 'raw source changes cannot approve an old card even after inference finished' do
    script_model({ tool: 'create_task', arguments: { title: 'Original pending review' } }, { text: 'Waiting for approval.' })
    execute
    card = @reply.reload.actions_list.first
    @trigger.update_columns(body: 'different request outside the editor')
    assert_no_difference -> { Projects::Task.count } do
      assert_raises(TeamChat::Actions::Denied) { TeamChat::Actions.decide!(@reply, card['id'], user: @user, approve: true) }
    end
    assert_equal 'proposed', TeamChat::Approval.find_by!(public_id: card['id']).state
  end

  test 'unchanged edits and edits after completion do not start another answer' do
    assert_no_difference -> { TeamChat::Run.count } do
      @trigger.edit_body!(@trigger.body)
    end
    assert_equal 0, @trigger.reload.request_revision
    script_model(text: 'Completed original.')
    execute
    assert_no_difference -> { TeamChat::Run.count } do
      edit
    end
    assert_equal 'succeeded', @run.reload.state
    assert_equal 'Completed original.', @reply.reload.body
  end

  test 'removing a mention in a mentions-only room stops rather than invents another request' do
    assert_no_difference -> { TeamChat::Run.count } do
      assert_nil edit('A note for the other people here')
    end
    assert_equal 'cancelled', @run.reload.state
  end

  test 'repeated edits supersede replacements and returning to the old text cannot revive the first run' do
    original = @trigger.body
    first_replacement = edit
    second_replacement = edit(original)
    assert_equal 'cancelled', @run.reload.state
    assert_equal 'cancelled', first_replacement.run.reload.state
    assert_equal 2, second_replacement.run.request_context['request_revision']
    assert_equal original, second_replacement.run.request_context['last_chat']
  end

  test 'a revoked requester cannot enqueue a replacement' do
    @user.update!(active: false)
    assert_no_difference -> { TeamChat::Run.count } do
      edit
    end
    assert_equal 'cancelled', @run.reload.state
  end

  test 'the full valid current request reaches the provider rather than the history excerpt limit' do
    marker = 'Final instruction: preserve this last sentence.'
    body = '@rupert ' + ('review ' * (TeamChat::Agent::TURN_CHARS / 7 + 20)) + marker
    assert_operator body.length, :<=, TeamChat::Message::BODY_MAX
    post = TeamChat::Post.call(room: @room, user: @user, body: body)
    requests = script_model(text: 'Reviewed the complete request.')
    execute(post.reply)
    assert_equal 'succeeded', post.reply.run.reload.state
    assert_includes requests.first['messages'].last['content'], marker
    assert_equal body, post.reply.run.request_context['last_chat']
  end

  test 'oversized edits are rejected rather than starting a silently truncated request' do
    body = @trigger.body
    assert_no_difference -> { TeamChat::Run.count } do
      assert_raises(ActiveRecord::RecordInvalid) { edit('x' * (TeamChat::Message::BODY_MAX + 1)) }
    end
    assert_equal body, @trigger.reload.body
    assert_equal 0, @trigger.request_revision
    assert_equal 'queued', @run.reload.state
  end

  test 'rate limiting rolls back the edit cancellation and replacement atomically' do
    body = @trigger.body
    TeamChat::Post.any_instance.stubs(:limited?).returns(true)
    assert_raises(TeamChat::Post::Limited) { edit }
    assert_equal body, @trigger.reload.body
    assert_equal 0, @trigger.request_revision
    assert_equal 'queued', @run.reload.state
  end

  test 'editing a shared source stops its private handoff and starts fresh work in the original room' do
    channel = TeamChat::Room.ensure_defaults!(@user)
    post = TeamChat::Post.call(room: channel, user: @user, body: '@rupert explain my task workflow')
    execute(post.reply)
    child = @room.messages.where(author_kind: 'assistant').order(:id).last
    assert_equal post.message.id, child.run.request_context['source_trigger_id']
    post.message.edit_body!('@rupert explain the revised task workflow')
    assert_equal 'cancelled', child.run.reload.state
    assert_equal 'succeeded', post.reply.run.reload.state
    fresh = post.message.revision_updates.select(&:pending?).last
    assert_equal channel.id, fresh.room_id
    execute(fresh)
    next_child = @room.messages.where(author_kind: 'assistant').order(:id).last
    assert_equal 1, next_child.run.request_context['source_request_revision']
    assert_equal post.message.body, next_child.run.request_context['last_chat']
    assert_equal post.message.edited_at.iso8601(6), next_child.run.request_context['requested_at']
  end

  test 'deleting the shared source invalidates private handoff recovery' do
    channel = TeamChat::Room.ensure_defaults!(@user)
    post = TeamChat::Post.call(room: channel, user: @user, body: '@rupert explain my task workflow')
    execute(post.reply)
    child = @room.messages.where(author_kind: 'assistant').order(:id).last
    child.run.claim!
    child.run.update!(lease_until: 1.second.ago)
    post.message.update_columns(deleted_at: Time.current)
    execute(child)
    assert_equal 'cancelled', child.run.reload.state
    assert_not_requested :post, "#{LLM_BASE}/chat/completions"
  end
end
