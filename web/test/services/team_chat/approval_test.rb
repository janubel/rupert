# frozen_string_literal: true

require 'test_helper'

class TeamChatApprovalTest < ActiveSupport::TestCase
  Crash = Class.new(Exception)

  setup do
    Current.tenant = tenants(:default_tenant)
    @user = users(:regular_user)
    Current.user = @user
    @room = TeamChat::Room.ensure_defaults!(@user)
    @trigger = @room.messages.create!(author_kind: 'person', user: @user, body: 'Please close the task.')
    @reply = @room.messages.create!(author_kind: 'assistant', status: 'pending', meta: { 'asked_by' => @user.id, 'trigger_id' => @trigger.id })
    TeamChat::Run.for_reply!(@reply).update!(configuration: { engine: 'openai', model: 'original-model' })
  end
  teardown { Current.reset }

  def propose(tool = 'create_task', arguments = { 'title' => 'One durable task' })
    @card = TeamChat::Actions.propose!(@reply, tool: tool, arguments: arguments, proposed_for: @user)
    @approval = TeamChat::Approval.find_by!(source_message_id: @reply.id, public_id: @card['id'])
    @card
  end

  def decide(approve: true, user: @user)
    TeamChat::Actions.decide!(TeamChat::Message.unscoped.find(@reply.id), @card['id'], user: user, approve: approve)
  end

  test 'duplicate approval returns the durable receipt with one effect notice and audit trail' do
    propose
    receipt = nil
    assert_difference -> { Projects::Task.count }, 1 do
      assert_difference -> { @room.messages.where(author_kind: 'system').count }, 1 do
        receipt = decide
        assert_equal receipt, decide
      end
    end
    assert_equal %w[proposed approved executed], @approval.events.order(:id).pluck(:kind)
    assert_equal receipt, @approval.reload.receipt
    assert_raises(TeamChat::Actions::Denied) { decide(approve: false) }
  end

  test 'canonical arguments and requester provenance survive later messages and JSON changes' do
    propose
    original = @approval.provenance.deep_dup
    later = @room.messages.create!(author_kind: 'person', user: @user, body: 'A later unrelated message')
    @reply.update!(actions: [@card.merge('arguments' => { 'title' => 'Tampered title' })], meta: { 'trigger_id' => later.id })
    decide
    task = Projects::Task.order(:id).last
    assert_equal 'One durable task', task.title
    assert_nil task.assignee_id
    assert_includes task.description, "Requested by #{@user.display_name}"
    assert_equal original, @approval.reload.provenance
    assert_equal @trigger.body, original['last_chat']
    assert_equal @trigger.id, original['trigger_id']
    assert_equal 'original-model', original['model']
    assert_match(/RubyLLM/, original['harness_version'])
  end

  test 'a tool error rolls back partial writes and saves an idempotent failed receipt' do
    propose
    Mcp::Tools::CreateTask.any_instance.expects(:call).once.with(@card['arguments']).raises(Mcp::ToolError.new('Rejected'))
    receipt = decide
    assert_equal 'failed', receipt['status']
    assert_equal receipt, decide
    assert_equal %w[proposed approved failed], @approval.events.order(:id).pluck(:kind)
  end

  test 'partial tool mutation is rolled back before recording a failure' do
    propose
    Mcp::Tools::CreateTask.any_instance.stubs(:call).with do |_args|
      Projects::Task.create!(title: 'Must roll back')
      raise Mcp::ToolError.new('Rejected after write')
    end
    assert_no_difference -> { Projects::Task.count } do
      assert_equal 'failed', decide['status']
    end
    assert_equal 'failed', @approval.reload.state
  end

  test 'a crash while saving the notice rolls back execution receipt and audit together' do
    propose
    TeamChat::Actions.stubs(:announce).raises(Crash)
    assert_no_difference -> { Projects::Task.count } do
      assert_raises(Crash) { decide }
    end
    assert_equal 'proposed', @approval.reload.state
    assert_equal ['proposed'], @approval.events.pluck(:kind)
    TeamChat::Actions.unstub(:announce)
    assert_difference -> { Projects::Task.count }, 1 do
      assert_equal 'done', decide['status']
    end
  end

  test 'closing a task records requester approver model harness and source without reassigning' do
    @room.update!(kind: 'channel')
    approver = User.create!(tenant: Current.tenant, name: 'Approving person', email: 'approver@example.com', role: @user.role, password: 'password123')
    task = Projects::Task.create!(title: 'Close this task', assignee_id: approver.id)
    propose('update_task', { 'task_id' => task.id, 'status' => 'done' })
    assert_equal 'done', decide(user: approver)['status']
    assert task.reload.done?
    assert_equal approver.id.to_s, task.assignee_id
    log = ActivityLog.for_subject('Projects::Task', task.id).where(action: 'team_chat_action').last!
    source = JSON.parse(log.details).fetch('source')
    assert_equal @user.id, source['requester_id']
    assert_equal @trigger.body, source['last_chat']
    assert_equal 'original-model', source['model']
    assert_equal 'TeamChat::Agent', source['harness']
    assert_equal @trigger.created_at.iso8601(6), source['requested_at']
    assert_equal approver.id, log.user_id
    assert_equal approver.id.to_s, @approval.reload.decided_by_id
    assert_equal "#{@room.slug}?message=#{@trigger.id}", source['chat_url'].delete_prefix('/chat/')
  end

  test 'an explicit assign to me remains assigned to the requester when someone else approves' do
    @room.update!(kind: 'channel')
    approver = User.create!(tenant: Current.tenant, name: 'Another approver', email: 'another-approver@example.com', role: @user.role, password: 'password123')
    propose('create_task', { 'title' => 'Mine explicitly', 'assign_to_me' => true })
    decide(user: approver)
    assert_equal @user.id.to_s, Projects::Task.order(:id).last.assignee_id
    assert_equal @user.id, @approval.provenance['assignee_id']
  end

  test 'reassigning an email after proposal cannot silently change its intended assignee' do
    proposed = User.create!(tenant: Current.tenant, name: 'Intended assignee', email: 'intended@example.com', role: @user.role, password: 'password123')
    propose('create_task', { 'title' => 'For intended person', 'assignee' => proposed.email })
    proposed.update!(email: 'renamed@example.com')
    User.create!(tenant: Current.tenant, name: 'Different assignee', email: 'intended@example.com', role: @user.role, password: 'password123')
    assert_no_difference -> { Projects::Task.count } do
      assert_raises(TeamChat::Actions::Denied) { decide }
    end
    assert_equal 'proposed', @approval.reload.state
  end

  test 'feedback approval is idempotent and keeps requester attribution in the audit' do
    propose('submit_feedback', { 'kind' => 'suggestion', 'summary' => 'One durable feedback item' })
    assert_difference -> { AgentFeedback.count }, 1 do
      receipt = decide
      assert_equal 'done', receipt['status']
      assert_equal receipt, decide
    end
    assert_equal @user.id, @approval.provenance['requester_id']
    assert_equal 1, @approval.events.where(kind: 'executed').count
  end

  test 'proposal audit failure cannot leave an orphan card or approval' do
    TeamChat::ApprovalEvent.any_instance.stubs(:save!).raises(ActiveRecord::RecordInvalid)
    assert_no_difference -> { TeamChat::Approval.count } do
      assert_raises(ActiveRecord::RecordInvalid) { propose }
    end
    assert_empty @reply.reload.actions_list
  end

  test 'editing the triggering message cannot rewrite the recorded request' do
    original = @trigger.body
    @trigger.update!(body: 'Changed after the AI started')
    propose
    assert_equal original, @approval.provenance['last_chat']
    assert_equal 'captured_at_run_creation', @approval.provenance['request_snapshot']
  end

  test 'thread attribution points at the actual requesting message and harness snapshot' do
    root = @room.messages.create!(author_kind: 'person', user: @user, body: 'Thread root')
    @trigger.update!(parent: root)
    @reply.run.destroy!
    @reply.reload
    TeamChat::Run.for_reply!(@reply)
    @reply.reload
    @card = TeamChat::Actions.propose!(@reply, tool: 'create_task', arguments: { 'title' => 'Thread request' }, proposed_for: @user,
      execution_info: { 'engine' => 'opencode_cli', 'model' => 'actual-cli-model', 'harness_version' => 'OpenCode CLI' })
    record = TeamChat::Approval.find_by!(public_id: @card['id'])
    assert_equal "/chat/#{@room.slug}?thread=#{root.id}&message=#{@trigger.id}", record.provenance['chat_url']
    assert_equal 'actual-cli-model', record.provenance['model']
    assert_equal 'OpenCode CLI', record.provenance['harness_version']
  end

  test 'legacy completed cards import as receipts and never execute again' do
    @card = { 'id' => 'legacy', 'tool' => 'create_task', 'arguments' => { 'title' => 'Never duplicate' }, 'status' => 'done', 'result' => 'Already created' }
    @reply.update!(actions: [@card])
    assert_no_difference -> { Projects::Task.count } do
      assert_equal @card, decide
      assert_equal @card, decide
    end
    record = TeamChat::Approval.find_by!(public_id: 'legacy')
    assert record.provenance['legacy']
    assert_nil record.provenance['harness_version']
    assert_equal ['legacy_imported'], record.events.pluck(:kind)
  end

  test 'revoked permissions and foreign tenant contexts cannot execute even a cached receipt' do
    propose
    decide
    @user.update!(active: false)
    assert_raises(TeamChat::Actions::Denied) { decide }
    @user.update!(active: true)
    Current.tenant = nil
    assert_raises(TeamChat::Actions::Denied) { decide }
  end

  test 'cancellation dismisses canonical approvals and prevents stale card approval' do
    propose
    @reply.run.cancel!(user: @user)
    assert_equal @user.id.to_s, @approval.events.find_by!(kind: 'cancelled').actor_id
    assert_equal 'dismissed', @approval.reload.state
    assert_equal %w[proposed cancelled], @approval.events.order(:id).pluck(:kind)
    assert_raises(TeamChat::Actions::Denied) { decide }
    assert_equal 'dismissed', @reply.reload.actions_list.first['status']
  end

  test 'cancellation uses canonical records even if the JSON projection is missing' do
    propose
    @reply.update!(actions: [])
    @reply.run.cancel!
    assert_equal 'dismissed', @approval.reload.state
    assert_equal 'dismissed', @reply.reload.actions_list.first['status']
    assert_raises(TeamChat::Actions::Denied) { decide }
  end

  test 'audit events and terminal receipts are immutable and survive message deletion' do
    propose
    decide
    assert_raises(ActiveRecord::ReadOnlyRecord) { @approval.events.first.update!(kind: 'forged') }
    assert_raises(ActiveRecord::ReadOnlyRecord) { @approval.events.first.destroy! }
    assert_raises(ActiveRecord::RecordInvalid) { @approval.reload.update!(receipt: { 'status' => 'proposed' }) }
    @reply.destroy!
    assert_nil @approval.reload.message_id
    assert_equal 'done', @approval.state
    assert_equal 3, @approval.events.count
    assert_equal @trigger.id, @approval.provenance['trigger_id']
  end
end
