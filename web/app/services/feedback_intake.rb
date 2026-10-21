# frozen_string_literal: true

# Files feedback that arrives from a teammate's chat message (Buzz) or an AI
# assistant, with the rules the owner set:
#   * the message text is untrusted data — stored capped, never followed;
#   * only senders on the allow-list (Settings → Environment, FEEDBACK_READY_SENDERS,
#     64-hex Nostr public keys or npubs) can mark work "ready for development";
#     everyone else's report is created for review only, whatever the text says;
#   * the same message is filed once (its id is the idempotency key);
#   * every action is written to the Activity log with the message it came from.
# Nothing here changes inventory, sales, Shopify, Square or deployments.
class FeedbackIntake
  class Error < StandardError; end

  KINDS = %w[bug request question direction].freeze
  TASK_KINDS = %w[bug request direction suggestion question].freeze
  SENDER_DAILY_LIMIT = 30
  TOTAL_DAILY_LIMIT = 150
  HEX = /\A[0-9a-f]{64}\z/

  Result = Struct.new(:feedback, :task, :duplicate, :ready, :ready_denied_reason, keyword_init: true)

  class << self
    # 64-hex public key for a hex key or an npub, nil for anything else.
    def normalize_sender(value)
      text = value.to_s.strip.downcase
      return text if text.match?(HEX)
      return unless text.start_with?('npub1')

      hrp, data = Nostr::Bech32.decode(text)
      hrp == 'npub' && data.to_s.match?(HEX) ? data.to_s : nil
    rescue StandardError
      nil
    end

    # The agent's own key is never a sender who can mark work ready, even if it is
    # listed: messages posted from Rupert's Team chat are signed by the agent
    # (with the person's name in the text, which is only text), so allowing that
    # key would let anyone with chat access skip the allow-list.
    def ready_senders
      own = BuzzChat.agent_pubkey
      EnvStore.fetch('FEEDBACK_READY_SENDERS', '').to_s.split(/[\s,;]+/).filter_map { |entry| normalize_sender(entry) }.uniq - [own].compact
    end

    def ready_sender?(sender)
      key = normalize_sender(sender)
      key.present? && ready_senders.include?(key)
    end

    # Where a person opens the report. Relative when the server has no public address set.
    def report_url(feedback)
      path = "/feedback_reports/#{feedback.id}"
      origin = ENV['RUPERT_PUBLIC_ORIGIN'].presence || ("https://#{ENV['RUPERT_INSTANCE_HOSTNAME']}" if ENV['RUPERT_INSTANCE_HOSTNAME'].present?)
      origin ? "#{origin.chomp('/')}#{path}" : path
    end

    def short_sender(sender) = sender.to_s.first(12).presence || 'unknown'
  end

  def self.file!(...)
    new(...).file!
  end

  def self.answered!(...)
    new(...).answered!
  end

  def initialize(source:, source_ref:, source_sender:, kind: nil, summary: nil, details: nil, severity: nil, ready: false, open_task: true,
                 agent_name: nil, user: nil, token: nil, note: nil)
    @source = source
    @source_ref = AgentFeedback.clean(source_ref, 120)
    @sender = AgentFeedback.clean(source_sender, 160)
    @kind = kind.to_s
    @summary = AgentFeedback.clean(summary, AgentFeedback::SUMMARY_MAX)
    @details = AgentFeedback.clean(details, AgentFeedback::DETAILS_MAX, multiline: true)
    @severity = AgentFeedback::SEVERITIES.include?(severity.to_s) ? severity.to_s : 'normal'
    @ready = ActiveModel::Type::Boolean.new.cast(ready) ? true : false
    @open_task = open_task
    @agent_name = AgentFeedback.clean(agent_name, 100)
    @user = user
    @token = token
    @note = AgentFeedback.clean(note, 300)
  end

  def file!
    raise Error, "kind must be one of #{AgentFeedback::KINDS.keys.join(', ')}." unless AgentFeedback::KINDS.key?(@kind)
    raise Error, 'A summary is required.' if @summary.blank?

    existing = AgentFeedback.find_by(source: @source, source_ref: @source_ref) if @source_ref
    return duplicate(existing) if existing

    enforce_limits!
    ready, denied = ready_decision
    feedback = AgentFeedback.create!(
      source: @source, source_ref: @source_ref, source_sender: @sender, kind: @kind, severity: @severity, summary: @summary, details: @details,
      agent_name: @agent_name, user_id: @user&.id, api_access_token_id: @token&.id,
      ready_for_development: ready, ready_marked_at: (Time.current if ready), ready_marked_by: (label_sender if ready)
    )
    task = open_task(feedback)
    log('feedback_intake_filed', feedback, "kind=#{@kind}; ready=#{ready ? 'yes' : 'no'}; task=#{task&.id || 'none'}")
    log('feedback_intake_ready_denied', feedback, "#{denied}") if denied
    Result.new(feedback: feedback, task: task, duplicate: false, ready: ready, ready_denied_reason: denied)
  rescue ActiveRecord::RecordInvalid => e
    raise Error, e.record.errors.full_messages.to_sentence
  end

  # A question the agent answered itself from read-only reports: nothing is filed, but the action is recorded.
  def answered!
    log('feedback_intake_answered', nil, "category=#{@kind.presence || 'question'}#{"; #{@note}" if @note}")
  end

  private

  def duplicate(existing)
    log('feedback_intake_duplicate', existing, 'the same message was already filed')
    Result.new(feedback: existing, task: existing.task, duplicate: true, ready: existing.ready_for_development)
  end

  def ready_decision
    return [false, nil] unless @ready
    return [false, 'ready for development was requested but the sender is not on the allow-list'] unless self.class.ready_sender?(@sender)
    return [false, 'ready for development needs a token with the tasks:write scope'] if @token && !@token.allows?('tasks:write')

    [true, nil]
  end

  def enforce_limits!
    scope = AgentFeedback.where(source: @source, created_at: 24.hours.ago..)
    raise Error, "Too many reports from #{@source} in the last 24 hours. Please wait." if scope.count >= TOTAL_DAILY_LIMIT
    raise Error, "This sender has filed #{SENDER_DAILY_LIMIT} reports in the last 24 hours. Please wait." if @sender && scope.where(source_sender: @sender).count >= SENDER_DAILY_LIMIT
  end

  def open_task(feedback)
    return unless @open_task && TASK_KINDS.include?(feedback.kind)

    line = "From #{@source}#{" message #{@source_ref.first(24)}" if @source_ref}, sender #{self.class.short_sender(@sender)}. " \
           "#{feedback.ready_for_development ? 'Marked ready for development by an allow-listed sender.' : 'For review: not marked ready for development.'}"
    FeedbackTask.create_for!(feedback, context_line: line)
  rescue StandardError => e
    Rails.error.report(e, handled: true, context: { feedback_id: feedback.id })
    nil
  end

  def label_sender = "#{@source}:#{self.class.short_sender(@sender)}"

  def log(action, feedback, details)
    ActivityLogger.log(action, subject: feedback, actor: @user,
      details: ["source=#{@source}", ("message=#{@source_ref}" if @source_ref), ("sender=#{self.class.short_sender(@sender)}" if @sender), details].compact.join('; ').first(500))
  end
end
