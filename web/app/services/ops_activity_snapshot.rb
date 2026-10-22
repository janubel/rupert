# frozen_string_literal: true

# Everything the System page "Recent errors and activity" card and the recent_errors MCP
# tool report from OpsEvent rows: counts per kind of problem, the latest distinct
# problems, and how logging is configured. Plain data only: no messages beyond the
# redacted summaries OpsLog wrote, no raw log lines.
class OpsActivitySnapshot
  WINDOW = 24.hours
  TILES = %w[server_error slow_request permission_denied rejected_form sign_in_failure job_failure].freeze
  # Kinds of problem that make the card say "needs attention" when they happened in the last hour.
  URGENT = %w[server_error exception job_failure sync_failure].freeze

  class << self
    def build(now: Time.current, limit: 10) = new(now, limit).build
  end

  def initialize(now, limit)
    @now = now
    @limit = limit
  end

  def build
    counts = OpsEvent.since(@now - WINDOW).group(:category).sum(:occurrences)
    {
      state: state(counts),
      window_hours: (WINDOW / 1.hour).to_i,
      counts: counts,
      tiles: TILES.map { |category| { category: category, label: OpsLog::Activity::CATEGORIES.fetch(category), count: counts.fetch(category, 0) } },
      recent: recent,
      config: config
    }
  end

  private

  def state(counts)
    urgent = OpsEvent.since(@now - 1.hour).errors.where(category: URGENT).exists?
    return 'error' if urgent

    counts.except('rate_limited', 'client_error').values.sum.positive? ? 'warning' : 'ok'
  end

  def recent
    OpsEvent.since(@now - WINDOW).recent.limit(@limit).map do |row|
      { id: row.id, kind: row.kind, category: row.category, label: OpsLog::Activity::CATEGORIES.fetch(row.category, 'Other'), level: row.level,
        summary: row.summary, occurrences: row.occurrences, first_seen_at: row.first_seen_at.iso8601, last_seen_at: row.last_seen_at.iso8601,
        request_id: row.request_id }
    end
  end

  def config
    {
      format: OpsLog.format, level: OpsLog.level_name,
      slow_request_ms: OpsLog.slow_request_ms, retention_days: OpsLog::Activity.retention_days, stored: OpsEvent.count,
      sentry: defined?(Sentry) && Sentry.initialized? ? true : false
    }
  end
end
