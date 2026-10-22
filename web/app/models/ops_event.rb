# frozen_string_literal: true

# A warning or error from OpsLog (see lib/ops_log.rb), kept so the System page and the
# recent_errors tool can show what went wrong in the web server and the job worker
# without reading raw logs. Not tenant scoped by default: callers filter explicitly.
class OpsEvent < ApplicationRecord
  LEVELS = %w[warn error fatal].freeze
  PRUNE_ONE_IN = 100

  scope :recent, -> { order(last_seen_at: :desc) }
  scope :since, ->(time) { where(last_seen_at: time..) }
  scope :errors, -> { where(level: %w[error fatal]) }

  validates :kind, :fingerprint, :first_seen_at, :last_seen_at, presence: true

  class << self
    # Never raises: a failed insert must not change the request or job being logged.
    def record!(kind:, category:, level:, summary:, fingerprint:, tenant_id:, user_id:, request_id:, data:)
      now = Time.current
      row = where(fingerprint: fingerprint).since(now - OpsLog::Activity::DEDUPE_WINDOW).order(last_seen_at: :desc).first
      payload = data.to_json.first(4000)
      if row
        where(id: row.id).update_all(['occurrences = occurrences + 1, last_seen_at = ?, request_id = ?, data = ?, summary = ?, level = ?',
                                      now, request_id, payload, summary, worst(row.level, level)])
      else
        create!(kind: kind, category: category, level: level, summary: summary.first(240), fingerprint: fingerprint, tenant_id: tenant_id, user_id: user_id,
          request_id: request_id, data: payload, first_seen_at: now, last_seen_at: now)
      end
      prune! if rand(PRUNE_ONE_IN).zero?
    rescue StandardError
      nil
    end

    def prune!
      where(last_seen_at: ...OpsLog::Activity.retention_days.days.ago).delete_all
      excess = count - OpsLog::Activity::MAX_ROWS
      where(id: order(:last_seen_at).limit(excess).select(:id)).delete_all if excess.positive?
    end

    def worst(a, b) = (LEVELS.index(a).to_i >= LEVELS.index(b).to_i ? a : b)
  end

  def fields = JSON.parse(data.presence || '{}').symbolize_keys
rescue JSON::ParserError
  {}
end
