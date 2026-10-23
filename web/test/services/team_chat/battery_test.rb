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

  test 'asks each question to the bot on its own in its test room, times it, grades it and posts a pinned summary' do
    requests = script_model({ tool: 'period_review', arguments: { period: 'yesterday' } }, { text: 'Yesterday: 2 orders, $100.' }, { text: 'No tax data.' })
    grader = FakeGrader.new([])
    battery = TeamChat::Battery.new(user: @user, agent: 'liquid', grader: grader, items: items, out: nil)
    results = battery.run

    room = TeamChat::Room.find_by!(slug: "test-liquid-#{@user.id}")
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
    assert_match(/Number check: figures not found in Rupert's data in 0 of 2 answers/, summary.body)
    report = battery.report_markdown
    assert_match(/\| 1 \| daily \| How did we do yesterday\? \| [\d.]+ s \| period_review \| 4 \|/, report)
  end

  test 'each run is saved with its per-question results, and the same model, set and build counts as already done' do
    script_model({ tool: 'period_review', arguments: { period: 'yesterday' } }, { text: 'Yesterday: 2 orders, $100.' }, { text: 'No tax data.' })
    battery = TeamChat::Battery.new(user: @user, agent: 'liquid', grader: FakeGrader.new([]), items: items, out: nil)
    battery.run

    run = TeamChat::BatteryRun.find_by!(run_key: battery.run_id)
    assert_equal ['done', 'default', 'liquid', 'lfm2.5-8b-a1b', 2, 2], [run.status, run.set_name, run.agent, run.model, run.questions, run.answered]
    assert_in_delta 4.0, run.avg_grade.to_f
    assert_equal({ 'daily' => 4.0, 'monthly' => 4.0 }, run.cadence_scores)
    assert_equal 0, run.flagged
    assert_equal %w[d1 m3], run.results_list.pluck('id')
    assert_empty run.results_list.first['unverified']
    assert_equal run, TeamChat::Battery.new(user: @user, agent: 'liquid', grader: FakeGrader.new([]), items: items, out: nil).already_done
    assert_nil TeamChat::Battery.new(user: @user, agent: 'liquid', only: ['d1'], grader: FakeGrader.new([]), items: items, out: nil).already_done
  end

  test 'runs from before saving are rebuilt from #liquid-testing' do
    room = TeamChat::Room.create!(name: 'liquid-testing', slug: 'liquid-testing', kind: 'channel', assistant_mode: 'off', created_by: @user)
    room.messages.create!(author_kind: 'system', body: '🧪 Test run old-1 (finance questions): 1 questions', meta: { 'battery' => 'old-1' })
    question = room.messages.create!(user: @user, body: '@qwen How much tax?', meta: { 'battery' => 'old-1', 'item' => 'f15', 'cadence' => 'tax' })
    reply = room.messages.create!(author_kind: 'assistant', status: 'done', body: 'Per source…',
      meta: { 'battery' => 'old-1', 'trigger_id' => question.id, 'agent' => 'qwen', 'model' => 'qwen3.5-4b', 'duration_ms' => 9000, 'tools' => ['sales_tax_report'] })
    room.messages.create!(author_kind: 'system', body: "Grade 5/5 for Qwen (9.0 s, sales_tax_report): Exact per source.\n— graded", meta: { 'battery' => 'old-1', 'grade' => 5, 'graded_message' => reply.id })
    room.messages.create!(author_kind: 'system', body: '📋 Test run old-1 done', meta: { 'battery' => 'old-1' })

    assert_equal 1, TeamChat::BatteryRun.backfill!
    assert_equal 0, TeamChat::BatteryRun.backfill!
    run = TeamChat::BatteryRun.find_by!(run_key: 'old-1')
    assert_equal ['done', 'finance', 'qwen', 5.0, 9.0], [run.status, run.set_name, run.agent, run.avg_grade.to_f, run.avg_seconds]
    assert_equal 'Exact per source.', run.results_list.first['verdict']
    assert_equal 'How much tax?', run.results_list.first['question']
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

  test 'every bot gets its own test room, created up front' do
    slugs = TeamChat::Battery.ensure_rooms!(@user).map(&:slug)
    assert_includes slugs, "test-rupert-#{@user.id}"
    assert_includes slugs, "test-liquid-#{@user.id}"
    assert_includes slugs, "test-gemma-e2b-#{@user.id}"
    assert_equal slugs.size, TeamChat::Room.where(slug: slugs).count
    assert TeamChat::Room.where(slug: slugs).all? { |room| room.direct? && room.created_by_id == @user.id }
    other = User.create!(tenant: @tenant, email: 'battery-peer@example.com', role: 'admin', password: 'password123')
    assert TeamChat::Room.where(slug: slugs).none? { |room| room.visible_to?(other) }
    assert TeamChat::Room.find_by(slug: "test-qwen-#{@user.id}").visible_to?(@user)
    assert_equal "rupert-#{@user.id}", TeamChat::Room.direct_for(@user).slug
  end

  test 'trial models are only for the battery, and an unknown bot is refused' do
    assert_equal 'gemma-4-e2b', TeamChat::LocalAgents.trial('gemma-e2b').model
    assert_nil TeamChat::LocalAgents.find('gemma-e2b')
    assert_raises(ArgumentError) { TeamChat::Battery.new(user: @user, agent: 'nobody', grader: FakeGrader.new([]), items: items, out: nil) }
    assert_equal 21, TeamChat::Battery.items.size
    finance = TeamChat::Battery.items(TeamChat::Battery.config_for('finance'))
    assert_equal 21, finance.size
    assert_match(/no cost of goods/, finance.find { |item| item.id == 'f20' }.expect)
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
