# frozen_string_literal: true

require 'test_helper'

class TeamChatLeaderboardTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
    @previous = ENV['RUPERT_LOCAL_LLM_URL']
    ENV['RUPERT_LOCAL_LLM_URL'] = 'http://10.0.0.7:8080/v1'
  end

  teardown do
    ENV['RUPERT_LOCAL_LLM_URL'] = @previous
    Current.reset
  end

  def run!(model, agent, set, grades, engine: 'local_gateway', status: 'done', started: 1.hour.ago)
    results = grades.map { |id, grade, cadence| { 'id' => id, 'cadence' => cadence || 'x', 'grade' => grade, 'seconds' => 10.0 } }
    TeamChat::BatteryRun.create!(run_key: SecureRandom.hex(4), set_name: set, agent: agent, model: model, engine: engine, status: status,
      questions: results.size, answered: results.size, results: results, avg_seconds: 10.0, started_at: started)
  end

  test 'scores each model out of 100 per module, crowns the leader and the best per column' do
    # d2/d3 are Sell, d5 is Stock, f15/f16 Bookkeeping (modules come from the battery files), f20/f21 honesty.
    qwen = [['d2', 5], ['d3', 5], ['d5', 4], ['f15', 5], ['f16', 5], ['f20', 3, 'honesty'], ['f21', 3, 'honesty']] * 3
    liquid = [['d2', 4], ['d3', 4], ['d5', 5], ['f15', 2], ['f16', 2], ['f20', 1, 'honesty'], ['f21', 1, 'honesty']] * 3
    run!('qwen3.6-35b-a3b', 'qwen-35b', 'finance', qwen)
    run!('lfm2.5-8b-a1b', 'liquid', 'finance', liquid)
    run!('lfm2.5-8b-a1b', 'liquid', 'finance', [['d2', 1]] * 21, started: 2.days.ago) # an older run of the same set is ignored
    run!('lfm2.5-8b-a1b', 'liquid', 'default (part)', [['d2', 1]] * 9) # partial runs never count

    rows = TeamChat::Leaderboard.call
    assert_equal %w[qwen3.6-35b-a3b lfm2.5-8b-a1b], rows.map(&:model)
    top, second = rows
    assert top.leader
    assert_not second.leader
    assert_equal ['qwen', 'local', 21], [top.handle, top.where, top.graded], 'the handle is the bot people use now (@qwen), not the test name'
    assert_equal 100, top.cells['sell'].score
    assert_equal 100, top.cells['bookkeeping'].score
    assert_equal 60, top.cells['honesty'].score
    assert top.cells['sell'].best
    assert second.cells['stock'].best, 'Liquid wins Stock (5 vs 4)'
    assert_equal 86, top.overall # (5+5+4+5+5+3+3)/7 = 4.29 -> 86
    assert_equal 'qwen3.6-35b-a3b', TeamChat::Leaderboard.leader_model
  end

  test 'no trophy under the minimum number of graded questions' do
    run!('gemma-4-e4b', 'gemma', 'default', [['d2', 5]] * 5)
    rows = TeamChat::Leaderboard.call
    assert_equal 1, rows.size
    assert_not rows.first.leader
    assert_nil TeamChat::Leaderboard.leader_model
  end

  test 'the cross-discipline set is tagged and loads' do
    items = TeamChat::Battery.items(TeamChat::Battery.config_for('cross'))
    assert_equal 10, items.size
    assert(items.all? { |item| item.module == 'cross' && item.expect.present? && item.checks.any? })
    assert(TeamChat::Battery.items.all?(&:module))
    assert(TeamChat::Battery.items(TeamChat::Battery.config_for('finance')).all?(&:module))
  end
end
