# frozen_string_literal: true

require 'test_helper'

class TeamChatActionsTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
    @user = users(:regular_user)
    Current.user = @user
    @room = TeamChat::Room.ensure_defaults!(@user)
    @reply = @room.messages.create!(author_kind: 'assistant', status: 'pending')
  end

  teardown { Current.reset }

  def propose(reply, title)
    TeamChat::Actions.propose!(reply, tool: 'create_task', arguments: { 'title' => title }, proposed_for: @user)
  end

  test 'a later proposal from the running agent preserves an approval and its receipt' do
    first = propose(@reply, 'Count the tea shelf')
    decided = nil
    assert_difference -> { Projects::Task.count }, 1 do
      decided = TeamChat::Actions.decide!(TeamChat::Message.find(@reply.id), first['id'], user: @user, approve: true)
    end
    assert_equal 'proposed', @reply.actions_list.first['status'], 'the running agent still holds the stale reply'

    second = propose(@reply, 'Count the coffee shelf')
    assert_equal [decided, second], @reply.reload.actions_list
    assert_equal 'done', @reply.actions_list.first['status']
    assert_no_difference -> { Projects::Task.count } do
      assert_raises(TeamChat::Actions::Denied) do
        TeamChat::Actions.decide!(@reply, first['id'], user: @user, approve: true)
      end
    end
  end

  test 'a later proposal preserves a dismissal made through another reply instance' do
    first = propose(@reply, 'Do not create this task')
    dismissed = TeamChat::Actions.decide!(TeamChat::Message.find(@reply.id), first['id'], user: @user, approve: false)

    second = propose(@reply, 'A different task')
    assert_equal [dismissed, second], @reply.reload.actions_list
    assert_no_difference -> { Projects::Task.count } do
      assert_raises(TeamChat::Actions::Denied) do
        TeamChat::Actions.decide!(@reply, first['id'], user: @user, approve: true)
      end
    end
  end

  test 'proposals from separate stale reply instances are both retained' do
    other_reply = TeamChat::Message.find(@reply.id)
    first = propose(@reply, 'First proposal')
    second = propose(other_reply, 'Second proposal')

    assert_equal [first, second], @reply.reload.actions_list
  end
end
