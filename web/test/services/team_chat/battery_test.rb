# frozen_string_literal: true

require 'test_helper'
require_relative '../../support/team_chat_helper'

class TeamChatBatteryTest < ActiveSupport::TestCase
  include TeamChatHelper

  FakeGrader = Struct.new(:calls) do
    def label = 'fake-grader'

    def grade(**kwargs)
      calls << kwargs
      { score: 4, verdict: 'Right totals, missed the top product.', issues: ['No top product'], seconds: 1.5 }
    end
  end

  setup do
    @tenant = tenants(:default_tenant)
    @user = users(:regular_user)
    Current.tenant = @tenant
    Current.user = @user
    @previous = ENV['RUPERT_LOCAL_LLM_URL']
    ENV['RUPERT_LOCAL_LLM_URL'] = LLM_BASE
  end

  teardown do
    ENV['RUPERT_LOCAL_LLM_URL'] = @previous
    Current.reset
  end

  def items
    [TeamChat::Battery::Item.new(id: 'd1', cadence: 'daily', question: 'How did we do yesterday?', checks: [{ 'tool' => 'period_review', 'args' => { 'period' => 'yesterday' } }]),
     TeamChat::Battery::Item.new(id: 'm3', cadence: 'monthly', question: 'Sales tax last month?', checks: [{ 'tool' => 'sales_tax_report', 'args' => { 'from' => 'last_month.from', 'to' => 'last_month.to' } }])]
  end

  test 'asks each question to the bot on its own in #liquid-testing, times it, grades it and posts a pinned summary' do
    requests = script_model({ tool: 'period_review', arguments: { period: 'yesterday' } }, { text: 'Yesterday: 2 orders, $100.' }, { text: 'No tax data.' })
    grader = FakeGrader.new([])
    battery = TeamChat::Battery.new(user: @user, agent: 'liquid', grader: grader, items: items, out: nil)
    results = battery.run

    room = TeamChat::Room.find_by!(slug: 'liquid-testing')
    assert_equal ['done', 'done'], results.map(&:status)
    assert_equal [['period_review'], []], results.map(&:tools)
    replies = room.messages.where(author_kind: 'assistant').order(:id)
    assert_equal %w[liquid liquid], replies.map { |reply| reply.meta['agent'] }
    assert_equal 'lfm2.5-8b-a1b', requests.first['model']
    # Each question stands alone: the second request does not carry the first question.
    assert_not_includes requests.last['messages'].map { |message| message['content'].to_s }.join, 'How did we do yesterday?'

    assert_equal 2, grader.calls.size
    assert_match(/period_review\(\{"period":"yesterday"\}\)/, grader.calls.first[:reference])
    assert_match(/"from":"#{Date.current.prev_month.beginning_of_month.iso8601}"/, grader.calls.last[:reference])
    grades = room.messages.where(author_kind: 'system').where('body LIKE ?', 'Grade %')
    assert_equal 2, grades.count
    assert_match(/Grade 4\/5 for Liquid .*Right totals.*\n- No top product\n— graded by fake-grader/m, grades.first.body)

    summary = room.messages.pinned.first
    assert_match(/answered 2\/2/, summary.body)
    assert_match(%r{Average grade 4.0/5}, summary.body)
    assert_match(/By cadence: daily 4.0 · monthly 4.0/, summary.body)
    report = battery.report_markdown
    assert_match(/\| 1 \| daily \| How did we do yesterday\? \| [\d.]+ s \| period_review \| 4 \|/, report)
  end

  test 'a proposal made during a test run is dismissed, so nothing changes' do
    script_model({ tool: 'create_task', arguments: { title: 'Recount' } }, { text: 'Proposed.' })
    item = TeamChat::Battery::Item.new(id: 'x', cadence: 'general', question: 'Make a task', checks: [])
    assert_no_difference -> { Projects::Task.count } do
      TeamChat::Battery.new(user: @user, agent: 'liquid', grader: FakeGrader.new([]), items: [item], out: nil).run
    end
    reply = TeamChat::Message.where(author_kind: 'assistant').last
    assert_equal 'dismissed', reply.actions_list.first['status']
  end

  test 'trial models are only for the battery, and an unknown bot is refused' do
    assert_equal 'gemma-4-e2b', TeamChat::LocalAgents.trial('gemma-e2b').model
    assert_nil TeamChat::LocalAgents.find('gemma-e2b')
    assert_raises(ArgumentError) { TeamChat::Battery.new(user: @user, agent: 'nobody', grader: FakeGrader.new([]), items: items, out: nil) }
    assert_equal 21, TeamChat::Battery.items.size
    finance = TeamChat::Battery.items(TeamChat::Battery.config_for('finance'))
    assert_equal 21, finance.size
    assert_equal %w[sales comparison money_out tax books honesty], finance.map(&:cadence).uniq
    assert_raises(ArgumentError) { TeamChat::Battery.config_for('../etc/passwd') }
    assert_raises(ArgumentError) { TeamChat::Battery.config_for('nope') }
    assert_equal TeamChat::Battery::CONFIG, TeamChat::Battery.config_for(nil)
  end

  test 'answers over two minutes are logged and listed on Model scores' do
    room = TeamChat::Room.ensure_defaults!(@user)
    asked = room.messages.create!(user: @user, body: '@liquid slow one')
    room.messages.create!(author_kind: 'assistant', status: 'done', body: 'Late answer',
      meta: { 'asked_by' => @user.id, 'trigger_id' => asked.id, 'agent' => 'liquid', 'model' => 'lfm2.5-8b-a1b', 'duration_ms' => 150_000 })
    room.messages.create!(author_kind: 'assistant', status: 'done', body: 'Quick', meta: { 'agent' => 'liquid', 'model' => 'lfm2.5-8b-a1b', 'duration_ms' => 20_000 })
    slow = TeamChat::ModelScores.slow
    assert_equal [[150, '@liquid slow one']], slow.map { |row| [row.seconds, row.question] }
    row = TeamChat::ModelScores.call.find { |score| score.agent == 'liquid' }
    assert_equal [1, 2, 50], [row.slow, row.answered, row.slow_percent]
  end
end
