# frozen_string_literal: true

# Everything the System page card and the `ai_health` MCP tool report about the
# opencode integration, built from AiHealthCheck and AiAgentRun rows. Plain
# data only: no key, no prompts, no replies.
class AiHealthSnapshot
  TREND_DAYS = 7
  WINDOW = 24.hours
  USAGE_API_NOTE = 'opencode publishes no balance or usage API for Zen or Go (usage is shown in the web console only), ' \
                   'so token counts here are the ones the @rupert agent logs from its own runs.'

  class << self
    def build(now: Time.current) = new(now).build
  end

  def initialize(now)
    @now = now
  end

  def build
    warnings = collect_warnings
    {
      state: state_for(warnings),
      warnings: warnings,
      key: key_info,
      last_check: last_check_info,
      free_models: { count: check&.free_model_count.to_i, ids: Array(check&.free_models) },
      model: model_info,
      tokens: token_info,
      rate_limits: rate_limit_info,
      agent: agent_info,
      usage_api: { available: false, note: USAGE_API_NOTE }
    }
  end

  private

  def check = (@check ||= [AiHealthCheck.latest]).first

  def window_runs = @window_runs ||= AiAgentRun.since(@now - WINDOW).to_a

  def key_info
    { state: check&.key_state || 'unchecked', code: check&.error_code }
  end

  def last_check_info
    return { checked_at: nil, status: nil, stale: true } unless check

    { checked_at: check.checked_at.iso8601, status: check.status, trigger: check.triggered_by, latency_ms: check.latency_ms,
      catalog_latency_ms: check.catalog_latency_ms, error_type: check.error_type, http_status: check.http_status,
      stale: check.stale?(now: @now) }
  end

  def model_info
    { id: check&.configured_model || OpencodeHealth.new.model, state: check&.model_state || 'unknown',
      provider: OpencodeHealth.new.provider }
  end

  def token_info
    start = @now.in_time_zone.beginning_of_day - (TREND_DAYS - 1).days
    runs = AiAgentRun.since(start).pluck(:occurred_at, :tokens_in, :tokens_out, :tokens_reasoning, :cache_read_tokens)
    days = (0...TREND_DAYS).map { |i| (start + i.days).to_date }
    by_day = days.index_with { { runs: 0, tokens_in: 0, tokens_out: 0, tokens_reasoning: 0, cache_read_tokens: 0 } }
    runs.each do |at, tin, tout, reasoning, cache|
      bucket = by_day[at.in_time_zone.to_date] or next
      bucket[:runs] += 1
      bucket[:tokens_in] += tin
      bucket[:tokens_out] += tout
      bucket[:tokens_reasoning] += reasoning
      bucket[:cache_read_tokens] += cache
    end
    trend = by_day.map { |date, sums| { date: date.iso8601 }.merge(sums) }
    { today: trend.last, trend: trend, week_total: trend.sum { |d| d[:tokens_in] + d[:tokens_out] + d[:tokens_reasoning] } }
  end

  def rate_limit_info
    week = AiAgentRun.since(@now - 7.days).where(outcome: 'rate_limited')
    last_run = week.maximum(:occurred_at)
    last_check = AiHealthCheck.where(rate_limited: true, checked_at: (@now - 7.days)..).maximum(:checked_at)
    last = [last_run, last_check].compact.max
    { runs_24h: window_runs.count { |r| r.outcome == 'rate_limited' }, runs_7d: week.count,
      checks_24h: AiHealthCheck.where(rate_limited: true, checked_at: (@now - WINDOW)..).count,
      last_hit_at: last&.iso8601 }
  end

  def agent_info
    last = AiAgentRun.order(occurred_at: :desc).first
    failures = window_runs.select { |r| r.outcome == 'error' }
    { last_run_at: last&.occurred_at&.iso8601, last_outcome: last&.outcome, runs_24h: window_runs.size,
      failures_24h: failures.size, failure_types_24h: failures.map(&:error_type).tally }
  end

  def collect_warnings
    [].tap do |list|
      add_check_warnings(list)
      add_run_warnings(list)
    end
  end

  def add_check_warnings(list)
    return list << flag('no_check', 'No provider check has run yet.') unless check

    list << flag('check_stale', 'The last provider check is old, so the periodic job may not be running.') if check.stale?(now: @now)
    case check.key_state
    when 'missing' then list << flag('key_missing', 'No opencode API key is configured for Rupert.', severity: 'info')
    when 'expired' then list << flag('key_expired', 'The opencode API key has expired. Create a new key in the OpenCode Console and replace it.', severity: 'error')
    when 'invalid' then list << flag('key_invalid', 'opencode rejected the API key.', severity: 'error')
    end
    if check.model_state == 'missing'
      list << flag('model_missing', "The model #{check.configured_model} is no longer in opencode's model list.", severity: 'error')
    end
    list << flag('no_free_models', 'opencode lists no free models right now.') if check.free_model_count.zero? && check.error_type.nil?
    list << flag('check_failed', "The last provider check failed (#{check.error_type}).") if check.error_type && !check.rate_limited && check.key_state == 'unchecked'
  end

  def add_run_warnings(list)
    limits = rate_limit_info
    hits = limits[:runs_24h] + limits[:checks_24h]
    list << flag('rate_limited', "opencode rate-limited Rupert #{hits} time#{'s' unless hits == 1} in the last 24 hours (free models have IP-level limits).") if hits.positive?
    failures = window_runs.count { |r| r.outcome == 'error' }
    list << flag('agent_failing', "#{failures} of the agent's last #{window_runs.size} runs (24 h) failed.") if failures.positive?
  end

  def flag(code, message, severity: 'warning')
    { code: code, severity: severity, message: message }
  end

  def state_for(warnings)
    return 'unknown' unless check
    return 'error' if warnings.any? { |w| w[:severity] == 'error' }
    return 'not_configured' if check.key_state == 'missing' && warnings.none? { |w| w[:severity] == 'warning' }

    warnings.any? { |w| w[:severity] == 'warning' } ? 'warning' : 'ok'
  end
end
