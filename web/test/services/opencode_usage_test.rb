# frozen_string_literal: true

require 'test_helper'

class OpencodeUsageTest < ActiveSupport::TestCase
  # Captured from `opencode run --standalone --format json` (v2.0.32).
  RUN = <<~JSON
    {"type":"step_start","timestamp":1792614025416,"sessionID":"ses_x","part":{"type":"step-start"}}
    {"type":"text","timestamp":1792614025442,"sessionID":"ses_x","part":{"type":"text","text":"ok"}}
    {"type":"step_finish","timestamp":1792614025452,"sessionID":"ses_x","part":{"type":"step-finish","reason":"stop","cost":0,"tokens":{"input":118,"output":2,"reasoning":0,"cache":{"read":5120,"write":0}}}}
  JSON

  test 'sums tokens, cost and steps from step-finish events' do
    two = RUN + RUN.lines.last.sub('"input":118', '"input":10').sub('"cost":0', '"cost":0.0125')
    summary = OpencodeUsage.parse(two, reply_present: true)
    assert_equal [128, 4, 0, 10_240, 0, 2], summary.to_a.values_at(0, 1, 2, 3, 4, 6)
    assert_in_delta 0.0125, summary.cost
    assert_equal 'ok', summary.outcome
    assert_nil summary.error_type
  end

  test 'a rate limit error event is classified without keeping its text' do
    raw = %({"type":"error","error":{"name":"APIError","data":{"statusCode":429,"message":"Free usage limit reached for your IP"}}}\n)
    summary = OpencodeUsage.parse(raw, reply_present: false)
    assert_equal 'rate_limited', summary.outcome
    assert_equal 'rate_limited', summary.error_type
  end

  test 'an authentication error is classified' do
    raw = %({"type":"error","error":{"name":"APIError","data":{"statusCode":401,"message":"api key expired"}}}\n)
    summary = OpencodeUsage.parse(raw, reply_present: false)
    assert_equal ['error', 'auth'], [summary.outcome, summary.error_type]
  end

  test 'CLI flag errors are visible as an error, not a silent skip' do
    raw = "ERRORS\n  Unrecognized flag: --pure in command opencode run\n"
    summary = OpencodeUsage.parse(raw, reply_present: false)
    assert_equal ['error', 'cli_error'], [summary.outcome, summary.error_type]
  end

  test 'no output at all is an error; steps without a reply are empty' do
    assert_equal %w[error no_output], OpencodeUsage.parse('', reply_present: false).to_a.values_at(7, 8)
    silent = RUN.lines.reject { |l| l.include?('"type":"text"') }.join
    assert_equal 'empty', OpencodeUsage.parse(silent, reply_present: false).outcome
  end

  test 'a timeout wins' do
    summary = OpencodeUsage.parse('', reply_present: false, timed_out: true)
    assert_equal ['timeout', 'timeout'], [summary.outcome, summary.error_type]
  end

  test 'record! stores counters only and never raises' do
    summary = OpencodeUsage.parse(RUN, reply_present: true)
    run = OpencodeUsage.record!(summary, model: 'deepseek-v4-flash', duration_ms: 812)
    assert_equal [118, 2, 5120, 'ok', 812], [run.tokens_in, run.tokens_out, run.cache_read_tokens, run.outcome, run.duration_ms]
    assert_not_includes AiAgentRun.column_names, 'content'
    AiAgentRun.stubs(:create!).raises(ActiveRecord::StatementInvalid)
    assert_nil OpencodeUsage.record!(summary, model: 'x', duration_ms: 1)
  end
end
