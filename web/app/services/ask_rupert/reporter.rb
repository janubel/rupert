# frozen_string_literal: true

module AskRupert
  # Hands a conversation to the Rupert team as a bug, request or question report.
  # It only ever runs because the person pressed Send (or Report this chat); a
  # model can prepare a draft but cannot file one. The words of the chat travel
  # with the report as an administrator-only attachment, with keys and card-like
  # numbers removed, so the team can see what was tried.
  class Reporter
    class Error < StandardError; end

    KINDS = FeedbackReport::KINDS.keys.index_with(&:itself).freeze
    DAILY_LIMIT = 10
    TURNS = 12
    TURN_CHARS = 600
    AGENT_NAME = 'Ask Rupert'

    def self.file!(...)
      new(...).file!
    end

    def initialize(user:, conversation:, kind:, summary:, details: nil)
      @user = user
      @conversation = conversation
      @kind = kind.to_s
      @summary = summary
      @details = details
    end

    def file!
      raise Error, 'Choose bug, request or question.' unless KINDS.key?(@kind)

      summary = AgentFeedback.clean(Redactor.clean(@summary), AgentFeedback::SUMMARY_MAX).to_s
      raise Error, 'Add a line saying what the report is about.' if summary.length < 3
      raise Error, "You have sent #{DAILY_LIMIT} reports from Ask Rupert today. Please try again tomorrow." if recent_reports >= DAILY_LIMIT

      feedback = AgentFeedback.new(
        source: 'app', user_id: @user.id, kind: KINDS.fetch(@kind), severity: 'normal', summary: summary, agent_name: AGENT_NAME,
        details: AgentFeedback.clean(Redactor.clean(@details), AgentFeedback::DETAILS_MAX, multiline: true).presence,
        related_reference: 'Ask Rupert chat',
        context: JSON.generate('source' => 'ask_rupert', 'conversation' => @conversation.id, 'role' => @user.role, 'build' => BuildInfo.current.short_revision)
      )
      AgentFeedback.transaction do
        feedback.save!
        feedback.attachments.create!(kind: 'conversation', content_type: 'text/plain', text_body: FeedbackAttachment.clip('conversation', transcript))
      end
      open_task(feedback)
      ActivityLogger.log('feedback_reported', subject: feedback, actor: @user,
        details: "source=ask_rupert; kind=#{feedback.kind}; conversation=#{@conversation.id}")
      feedback
    rescue ActiveRecord::RecordInvalid => e
      raise Error, e.record.errors.full_messages.to_sentence
    end

    private

    def recent_reports
      AgentFeedback.where(user_id: @user.id, agent_name: AGENT_NAME, created_at: 24.hours.ago..).count
    end

    # What was said, as the team will read it. Secrets and card-like numbers are already removed.
    def transcript
      @conversation.messages.where(status: %w[done failed]).order(:id).last(TURNS).map do |message|
        "#{message.role == 'user' ? 'Person' : 'Ask Rupert'}: #{Redactor.clean(message.content).first(TURN_CHARS)}"
      end.join("\n")
    end

    # Same path as the ladybug: a task in the Rupert Feedback project linking to the report.
    def open_task(feedback)
      FeedbackTask.create_for!(feedback, context_line: 'From an Ask Rupert chat; the conversation is attached to the report (administrators only).')
    rescue StandardError => e
      Rails.error.report(e, handled: true, context: { feedback_id: feedback.id })
    end
  end
end
