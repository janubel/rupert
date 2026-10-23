# frozen_string_literal: true

require 'test_helper'
require 'timeout'

class TeamChatApprovalRestartTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @tenant = tenants(:default_tenant)
    @user = users(:regular_user)
    Current.tenant = @tenant
    Current.user = @user
    @title = "Approval restart #{SecureRandom.hex(6)}"
    @room = TeamChat::Room.create!(name: @title, slug: "approval-#{SecureRandom.hex(6)}", kind: 'direct', created_by: @user, assistant_mode: 'off')
    trigger = @room.messages.create!(author_kind: 'person', user: @user, body: "Create the task #{@title}.")
    @reply = @room.messages.create!(author_kind: 'assistant', status: 'pending', meta: { 'asked_by' => @user.id, 'trigger_id' => trigger.id })
    TeamChat::Run.for_reply!(@reply).claim!
    @card = TeamChat::Actions.propose!(@reply, tool: 'create_task', arguments: { 'title' => @title }, proposed_for: @user)
    @approval = TeamChat::Approval.find_by!(source_message_id: @reply.id, public_id: @card['id'])
  end

  teardown do
    Current.tenant = @tenant
    Projects::Task.where(title: @title).destroy_all
    ActivityLog.where(action: 'team_chat_action').where('details LIKE ?', "%\"approval_id\":#{@approval.id},%").delete_all
    @room.destroy!
    TeamChat::ApprovalEvent.where(approval_id: @approval.id).delete_all
    TeamChat::Approval.where(id: @approval.id).delete_all
    Current.reset
  end

  def decide
    TeamChat::Actions.decide!(TeamChat::Message.find(@reply.id), @card['id'], user: @user, approve: true)
  end

  test 'simultaneous approvals execute once and both return the same committed receipt' do
    gate = Queue.new
    results = Queue.new
    actors = 2.times.map do
      Thread.new do
        gate.pop
        ActiveRecord::Base.connection_pool.with_connection do
          Current.tenant = @tenant
          Current.user = @user
          results << decide
        rescue StandardError => e
          results << e
        ensure
          Current.reset
        end
      end
    end
    2.times { gate << true }
    actors.each(&:join)
    receipts = 2.times.map { results.pop }
    assert receipts.all? { |receipt| receipt.is_a?(Hash) }, receipts.map(&:inspect).join('; ')
    assert_equal receipts.first, receipts.last
    assert_equal 1, Projects::Task.where(title: @title).count
    assert_equal 1, @room.messages.where(author_kind: 'system').count
    assert_equal %w[proposed approved executed], @approval.events.order(:id).pluck(:kind)
  end

  test 'SIGKILL after mutation but before receipt commits rolls back and retries once' do
    crash_process(before_commit: true)
    assert_equal 'proposed', @approval.reload.state
    assert_equal 0, Projects::Task.where(title: @title).count
    assert_equal ['proposed'], @approval.events.pluck(:kind)
    assert_equal 'done', decide['status']
    assert_equal 1, Projects::Task.where(title: @title).count
  end

  test 'SIGKILL after commit but before response delivery replays the saved receipt' do
    crash_process(before_commit: false)
    assert_equal 'done', @approval.reload.state
    saved = @approval.receipt
    assert_equal saved, decide
    assert_equal 1, Projects::Task.where(title: @title).count
    assert_equal 1, @room.messages.where(author_kind: 'system').count
    assert_equal 3, @approval.events.count
  end

  def crash_process(before_commit:)
    reader, writer = IO.pipe
    ActiveRecord::Base.connection_handler.clear_all_connections!
    child = fork do
      reader.close
      ActiveRecord::Base.establish_connection
      if before_commit
        TeamChat::Actions.stubs(:announce).with do |_message, _action|
          writer.write('mutated')
          writer.flush
          Process.kill('KILL', Process.pid)
        end
      end
      decide
      writer.write('committed')
      writer.flush
      Process.kill('KILL', Process.pid)
    end
    writer.close
    assert_equal(before_commit ? 'mutated' : 'committed', Timeout.timeout(10) { reader.read })
    _, status = Process.waitpid2(child)
    child = nil
    assert_equal Signal.list.fetch('KILL'), status.termsig
  ensure
    Process.kill('KILL', child) if child
    Process.waitpid(child) if child
    reader&.close unless reader&.closed?
    writer&.close unless writer&.closed?
  end
end
