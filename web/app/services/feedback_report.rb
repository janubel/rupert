# frozen_string_literal: true

# Files a report sent from the ladybug: the person's words become a feedback
# row, their diagnostics become admin-only attachments, and a task is opened in
# the Rupert Feedback project. Everything supplied by the browser is untrusted:
# it is cleaned, capped and scrubbed here and shown escaped afterwards.
class FeedbackReport
  class Error < StandardError; end

  KINDS = { 'bug' => 'Bug', 'request' => 'Request', 'question' => 'Question' }.freeze
  DAILY_LIMIT = 30
  MIN_WORDS_LENGTH = 5
  CLIENT_KEYS = %w[viewport screen pixel_ratio language timezone theme online touch page_title].freeze
  ERROR_KEYS = %w[message source line column stack at].freeze
  MAX_ERRORS = 10

  def self.submit!(...)
    new(...).submit!
  end

  def initialize(user:, params:, request:, trace_key: nil)
    @user = user
    @params = params
    @request = request
    @trace_key = trace_key
  end

  def submit!
    kind = @params[:kind].to_s
    raise Error, 'Choose bug, request or question.' unless KINDS.key?(kind)

    details = AgentFeedback.clean(@params[:description], AgentFeedback::DETAILS_MAX, multiline: true)
    raise Error, "Tell us a little more (at least #{MIN_WORDS_LENGTH} characters)." if details.to_s.length < MIN_WORDS_LENGTH
    raise Error, "You have sent #{DAILY_LIMIT} reports today. Please try again tomorrow." if AgentFeedback.reported_by(@user).where(created_at: 24.hours.ago..).count >= DAILY_LIMIT

    feedback = AgentFeedback.new(
      source: 'app', user_id: @user.id, kind: kind, severity: severity(kind), summary: summary(details), details: details,
      related_reference: FeedbackSanitizer.scrub_url(@params[:page_url], max: 300),
      context: JSON.generate(page_context)
    )
    AgentFeedback.transaction do
      feedback.save!
      attachments.each { |kind_name, attributes| feedback.attachments.create!(attributes.merge(kind: kind_name)) }
    end
    open_task(feedback)
    ActivityLogger.log('feedback_reported', subject: feedback, actor: @user,
      details: "kind=#{kind}; severity=#{feedback.severity}; task=#{feedback.task_id}; attachments=#{feedback.attachments.map(&:kind).join(',')}")
    feedback
  rescue ActiveRecord::RecordInvalid => e
    raise Error, e.record.errors.full_messages.to_sentence
  end

  private

  def severity(kind)
    value = @params[:severity].to_s
    kind == 'bug' && AgentFeedback::SEVERITIES.include?(value) ? value : 'normal'
  end

  def summary(details)
    AgentFeedback.clean(details.lines.first.to_s.squish, AgentFeedback::SUMMARY_MAX) || 'Report from Rupert'
  end

  def page_context
    { 'page' => FeedbackSanitizer.scrub_url(@params[:page_url], max: 200), 'build' => BuildInfo.current.short_revision,
      'page_request_id' => @params[:page_request_id].to_s.gsub(/[^\w-]/, '').first(64).presence, 'role' => @user.role }.compact
  end

  def open_task(feedback)
    FeedbackTask.create_for!(feedback, context_line: ("Page: #{feedback.related_reference}" if feedback.related_reference))
  rescue StandardError => e
    # The report is saved; a missing task can be created from the review page.
    Rails.error.report(e, handled: true, context: { feedback_id: feedback.id })
  end

  def attachments
    {
      'client_context' => text_attachment('client_context', 'application/json', JSON.pretty_generate(client_context)),
      'js_errors' => text_attachment('js_errors', 'application/json', js_errors),
      'dom_snapshot' => text_attachment('dom_snapshot', 'text/html', @params[:dom_snapshot]),
      'server_log' => text_attachment('server_log', 'text/plain', server_log),
      'sql_queries' => text_attachment('sql_queries', 'text/plain', sql_queries),
      'screenshot' => screenshot
    }.compact
  end

  def text_attachment(kind, content_type, text)
    return if text.blank?

    { content_type: content_type, text_body: FeedbackAttachment.clip(kind, FeedbackSanitizer.scrub_text(text)) }
  end

  def screenshot
    file = @params[:screenshot]
    return unless file.respond_to?(:read)

    bytes = file.read(FeedbackAttachment::SCREENSHOT_LIMIT + 1).to_s.b
    type = FeedbackAttachment.image_type(bytes)
    return unless type && bytes.bytesize <= FeedbackAttachment::SCREENSHOT_LIMIT

    { content_type: type, binary_body: bytes }
  end

  def client_context
    sent = parse_json(@params[:client]).then { |hash| hash.is_a?(Hash) ? hash : {} }
    sent.slice(*CLIENT_KEYS).transform_values { |value| value.is_a?(String) ? value.first(200) : value.as_json.to_s.first(200) }.merge(
      'page' => FeedbackSanitizer.scrub_url(@params[:page_url]), 'build' => BuildInfo.current.revision, 'built_at' => BuildInfo.current.built_at&.iso8601,
      'user_agent' => @request.user_agent.to_s.first(300), 'report_request_id' => @request.request_id,
      'page_request_id' => @params[:page_request_id].to_s.gsub(/[^\w-]/, '').first(64).presence, 'reporter_role' => @user.role,
      'reported_at' => Time.current.iso8601
    ).compact
  end

  def js_errors
    list = parse_json(@params[:js_errors])
    return unless list.is_a?(Array) && list.any?

    JSON.pretty_generate(list.first(MAX_ERRORS).filter_map do |item|
      item.slice(*ERROR_KEYS).transform_values { |value| value.to_s.first(1000) } if item.is_a?(Hash)
    end)
  end

  def server_log
    requests = RequestTrace.recent(@trace_key)
    return if requests.empty?

    requests.map do |entry|
      ["#{entry.at.utc.iso8601} #{entry.method} #{entry.path} -> #{entry.status} in #{entry.duration_ms}ms (request #{entry.request_id})",
       *entry.lines.map { |line| "  #{line}" }].join("\n")
    end.join("\n\n")
  end

  def sql_queries
    requests = RequestTrace.recent(@trace_key).reject { |entry| entry.queries.empty? }
    return if requests.empty?

    requests.map do |entry|
      ["#{entry.method} #{entry.path} (request #{entry.request_id})",
       *entry.queries.map { |query| "  #{query[:ms]}ms #{query[:name]}#{' [cached]' if query[:cached]} #{query[:sql]}" }].join("\n")
    end.join("\n\n")
  end

  def parse_json(text)
    JSON.parse(text.to_s.first(60_000)) if text.present?
  rescue JSON::ParserError
    nil
  end
end
