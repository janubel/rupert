# frozen_string_literal: true

require 'test_helper'
require_relative '../../support/team_chat_helper'

class TeamChatRouterTest < ActiveSupport::TestCase
  include TeamChatHelper

  setup do
    @tenant = tenants(:default_tenant)
    @user = users(:regular_user)
    Current.tenant = @tenant
    Current.user = @user
    @room = TeamChat::Room.direct_for(@user)
    @room.update!(assistant_mode: 'all')
    @previous = ENV['RUPERT_LOCAL_LLM_URL']
    ENV['RUPERT_LOCAL_LLM_URL'] = LLM_BASE
  end

  teardown do
    ENV['RUPERT_LOCAL_LLM_URL'] = @previous
    Current.reset
  end

  def post(text) = TeamChat::Post.call(room: @room, user: @user, body: text)
  def answered_by(result) = result.replies.map { |reply| reply.meta['agent'] || 'rupert' }

  test 'questions are sorted into general, finance, cross and think harder' do
    {
      'Which tasks are overdue?' => 'general',
      'Any open stock alerts I should look at today?' => 'general',
      'How much sales tax did we collect last month?' => 'finance',
      'Is last month closed in the books?' => 'finance',
      'Are there paid online orders that have not shipped yet?' => 'finance',
      'How many hours did the team work last pay week, and how did sales do over the same days?' => 'cross',
      'Which of last month\'s top-selling products are low on stock right now?' => 'cross',
      'Think harder: why did the shelf count drift?' => 'think',
      'Hello there' => 'general'
    }.each { |question, kind| assert_equal kind, TeamChat::Router.kind_for(question), question }
  end

  test 'a question with no bot named goes where routing.yml says' do
    assert_equal ['qwen'], answered_by(post('Which tasks are overdue?'))

    finance = post('How much sales tax did we collect last month?')
    assert_equal %w[rupert qwen], answered_by(finance)
    assert(finance.replies.all? { |reply| reply.meta['compare_of'] == finance.message.id && reply.meta['route'] == 'finance' }, 'side by side')

    assert_equal ['rupert'], answered_by(post('How many hours did the team work last pay week, and how did sales do over the same days?'))
    assert_equal ['flint-think'], answered_by(post('Think it through: which tasks matter most this week?'))
  end

  test 'naming a bot, or @rupert, skips routing' do
    assert_equal ['gemma'], answered_by(post('@gemma which tasks are overdue?'))
    assert_equal ['rupert'], answered_by(post('@rupert which tasks are overdue?'))
  end

  test 'without the local model server everything goes to @rupert' do
    ENV['RUPERT_LOCAL_LLM_URL'] = nil
    assert_equal ['rupert'], answered_by(post('Which tasks are overdue?'))
  end

  test 'a local reply that repeats the question line first has it removed' do
    script_model({ text: "#{@user.display_name}: @qwen how many tasks?\n\nThere are 3 open tasks." })
    @room.update!(assistant_mode: 'mentions')
    reply = post('@qwen how many tasks?').replies.first
    TeamChat::Agent.new(reply).run

    assert_equal 'There are 3 open tasks.', reply.reload.body
  end
end
