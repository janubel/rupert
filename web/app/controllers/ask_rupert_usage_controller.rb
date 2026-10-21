# frozen_string_literal: true

# Administrators see how much Ask Rupert is used (counts and tokens, never
# message text) and adjust its light limits. Settings readers view; settings
# writers change.
class AskRupertUsageController < AuthenticatedController
  before_action -> { authorize(:module, :settings_read?) }
  before_action -> { authorize(:module, :settings_write?) }, only: :update
  before_action -> { response.headers['Cache-Control'] = 'no-store' }

  def show
    @config = AskRupert::Config.current
    @since_day = 24.hours.ago
    @since_week = 7.days.ago
    week = AskRupert::Usage.since(@since_week)
    @totals = { questions: week.accepted.count, limited: week.where(outcome: 'limited').count, failed: week.where(outcome: 'error').count,
                tokens: week.sum('tokens_in + tokens_out'), tool_calls: week.sum(:tool_calls) }
    @by_provider = week.accepted.group(:provider, :model).pluck(:provider, :model, Arel.sql('COUNT(*)'), Arel.sql('SUM(tokens_in + tokens_out)'))
    @people = person_rows(week)
    @conversations = AskRupert::Conversation.count
  end

  def update
    values = params.fetch(:ask_rupert, {}).permit(*AskRupert::Config::EDITABLE)
    AskRupert::Config.update!(values)
    ActivityLogger.log('ask_rupert_settings_updated', details: "settings=#{values.keys.sort.join(',')}")
    redirect_to ask_rupert_usage_path, notice: 'Ask Rupert settings saved.'
  end

  private

  def person_rows(week)
    day = week.accepted.where(created_at: @since_day..).group(:user_id).count
    grouped = week.accepted.group(:user_id).pluck(:user_id, Arel.sql('COUNT(*)'), Arel.sql('SUM(tokens_in + tokens_out)'), Arel.sql('MAX(created_at)'))
    limited = week.where(outcome: 'limited').group(:user_id).count
    users = User.where(id: grouped.map(&:first)).index_by(&:id)
    grouped.map do |user_id, count, tokens, last|
      { name: users[user_id]&.display_name || "User #{user_id}", day: day.fetch(user_id, 0), week: count, tokens: tokens.to_i,
        limited: limited.fetch(user_id, 0), last: last && Time.zone.parse(last.to_s) }
    end.sort_by { |row| -row[:week] }
  end
end
