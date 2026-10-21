# frozen_string_literal: true

require 'test_helper'

class AiHealthSnapshotTest < ActiveSupport::TestCase
  setup do
    AiHealthCheck.delete_all
    AiAgentRun.delete_all
    @now = Time.zone.local(2026, 10, 21, 15, 0, 0)
  end

  def check!(**attrs)
    AiHealthCheck.create!({ status: 'ok', key_state: 'valid', model_state: 'available', configured_model: 'deepseek-v4-flash',
                            free_models: %w[beam-free], free_model_count: 1, checked_at: @now - 5.minutes }.merge(attrs))
  end

  def run!(at:, outcome: 'ok', tokens_in: 100, tokens_out: 10, **attrs)
    AiAgentRun.create!({ outcome: outcome, tokens_in: tokens_in, tokens_out: tokens_out, occurred_at: at }.merge(attrs))
  end

  test 'before any check the state is unknown with a warning' do
    snap = AiHealthSnapshot.build(now: @now)
    assert_equal 'unknown', snap[:state]
    assert_equal ['no_check'], snap[:warnings].map { |w| w[:code] }
  end

  test 'healthy snapshot' do
    check!
    snap = AiHealthSnapshot.build(now: @now)
    assert_equal 'ok', snap[:state]
    assert_empty snap[:warnings]
    assert_equal({ count: 1, ids: %w[beam-free] }, snap[:free_models])
    assert_equal 'available', snap[:model][:state]
    assert_equal false, snap[:usage_api][:available]
  end

  test 'tokens today and a 7-day trend by local day' do
    check!
    run!(at: @now - 1.hour, tokens_in: 100, tokens_out: 10)
    run!(at: @now - 2.hours, tokens_in: 50, tokens_out: 5, tokens_reasoning: 3)
    run!(at: @now - 1.day, tokens_in: 7, tokens_out: 1)
    run!(at: @now - 10.days, tokens_in: 999, tokens_out: 999)
    snap = AiHealthSnapshot.build(now: @now)
    today = snap[:tokens][:today]
    assert_equal [150, 15, 3, 2], today.values_at(:tokens_in, :tokens_out, :tokens_reasoning, :runs)
    assert_equal 7, snap[:tokens][:trend].size
    assert_equal '2026-10-15', snap[:tokens][:trend].first[:date]
    assert_equal 8, snap[:tokens][:trend][-2][:tokens_in] + snap[:tokens][:trend][-2][:tokens_out]
    assert_equal 176, snap[:tokens][:week_total]
  end

  test 'an expired key and a missing model are errors' do
    check!(status: 'error', key_state: 'expired', error_code: 'api_key_expired', model_state: 'missing')
    snap = AiHealthSnapshot.build(now: @now)
    assert_equal 'error', snap[:state]
    assert_equal %w[key_expired model_missing], snap[:warnings].map { |w| w[:code] }
    assert_equal 'api_key_expired', snap[:key][:code]
  end

  test 'rate-limit hits from agent runs and checks are counted and warned about' do
    check!(rate_limited: true, error_type: 'rate_limited')
    run!(at: @now - 1.hour, outcome: 'rate_limited', error_type: 'rate_limited')
    run!(at: @now - 3.days, outcome: 'rate_limited', error_type: 'rate_limited')
    snap = AiHealthSnapshot.build(now: @now)
    assert_equal 'warning', snap[:state]
    assert_equal [1, 2, 1], snap[:rate_limits].values_at(:runs_24h, :runs_7d, :checks_24h)
    assert_includes snap[:warnings].map { |w| w[:code] }, 'rate_limited'
    assert_not_nil snap[:rate_limits][:last_hit_at]
  end

  test 'failing agent runs are warned about with their types' do
    check!
    run!(at: @now - 1.hour, outcome: 'error', error_type: 'no_output')
    run!(at: @now - 2.hours)
    snap = AiHealthSnapshot.build(now: @now)
    assert_equal({ 'no_output' => 1 }, snap[:agent][:failure_types_24h])
    assert_includes snap[:warnings].map { |w| w[:code] }, 'agent_failing'
  end

  test 'a stale check says the periodic job may not be running' do
    check!(checked_at: @now - 5.hours)
    snap = AiHealthSnapshot.build(now: @now)
    assert snap[:last_check][:stale]
    assert_includes snap[:warnings].map { |w| w[:code] }, 'check_stale'
  end

  test 'no key configured is not_configured, not an error' do
    check!(status: 'not_configured', key_state: 'missing')
    snap = AiHealthSnapshot.build(now: @now)
    assert_equal 'not_configured', snap[:state]
  end

  test 'no free models is a warning' do
    check!(free_models: [], free_model_count: 0)
    assert_equal 'warning', AiHealthSnapshot.build(now: @now)[:state]
  end
end
