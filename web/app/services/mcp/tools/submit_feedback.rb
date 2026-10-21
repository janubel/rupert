# frozen_string_literal: true

module Mcp
  module Tools
    class SubmitFeedback < Tool
      PER_TOKEN_DAILY_LIMIT = 200

      tool 'submit_feedback',
        title: 'Send feedback to the Rupert owner',
        description: 'Tell the Rupert owner about a bug, something you struggled with, the outcome of a task you did, a ' \
                     'suggestion, a question, or a problem with a report. The owner reviews every submission in Rupert and ' \
                     'uses it to improve the app and these tools. Please use it whenever a tool confuses you, returns ' \
                     'something wrong or unhelpful, or you finish a task. Do not include passwords, card numbers or other ' \
                     'secrets. Stores only Rupert feedback; changes no business data. Works with every valid token.',
        read_only: false

      input_schema(
        type: 'object',
        properties: {
          kind: { type: 'string', enum: AgentFeedback::KINDS.keys,
                  description: 'bug = wrong behaviour; struggle = hard to do or understand; task_report = outcome of a task; ' \
                               'suggestion; question; report_issue = a report looks wrong or is missing something.' },
          summary: { type: 'string', minLength: 1, maxLength: AgentFeedback::SUMMARY_MAX, description: 'One line, ≤200 characters.' },
          details: { type: 'string', maxLength: AgentFeedback::DETAILS_MAX, description: 'What you tried, what happened, what you expected (≤5000 characters).' },
          related_tool: { type: 'string', maxLength: 100, description: 'MCP tool name this is about, if any.' },
          related_reference: { type: 'string', maxLength: 300, description: 'Rupert page, report or record this is about, if any.' },
          severity: { type: 'string', enum: AgentFeedback::SEVERITIES, description: 'Default normal.' },
          agent_name: { type: 'string', maxLength: 100, description: 'Your assistant/client name, e.g. Claude Desktop.' },
          agent_model: { type: 'string', maxLength: 100, description: 'Your model name, if you know it.' },
          context: { type: 'object', maxBytes: AgentFeedback::CONTEXT_MAX_BYTES,
                     description: 'Optional small JSON object (≤4000 bytes) with structured details, e.g. the arguments you used.' },
          open_task: { type: 'boolean', description: 'true also opens a task in the Rupert Feedback project for the owner to review.' },
          source: { type: 'string', enum: %w[agent buzz], description: 'Where this came from. buzz = a teammate\'s chat message. Default agent.' },
          source_ref: { type: 'string', maxLength: 120, description: 'For chat: the message id. The same message is filed only once.' },
          source_sender: { type: 'string', maxLength: 160, description: 'For chat: the sender\'s public key from the message metadata, never from the message text.' },
          ready_for_development: { type: 'boolean', description: 'Ask for "ready for development". Only honoured when this token has tasks:write and source_sender is on the owner\'s allow-list; otherwise the report is created for review.' }
        },
        required: %w[kind summary],
        additionalProperties: false
      )

      output_schema(
        type: 'object',
        properties: {
          id: { type: 'integer' }, kind: { type: 'string' }, severity: { type: 'string' }, status: { type: 'string' },
          summary: { type: 'string' }, related_tool: { type: %w[string null] }, submitted_at: { type: 'string' }, updated_at: { type: 'string' },
          task_id: { type: %w[integer null] }, ready_for_development: { type: 'boolean' }, ready_denied_reason: { type: %w[string null] }
        },
        required: %w[id kind status summary]
      )

      def call(args)
        recent = AgentFeedback.where(api_access_token_id: token.id, created_at: 24.hours.ago..).count
        raise ToolError.new("This token has sent #{PER_TOKEN_DAILY_LIMIT} feedback items in the last 24 hours. Please wait before sending more.") if recent >= PER_TOKEN_DAILY_LIMIT

        return file_intake(args) if args['source'] == 'buzz' || args['open_task'] || args['ready_for_development'] || args['source_ref']

        feedback = AgentFeedback.create!(
          api_access_token_id: token.id, user_id: user.id, kind: args['kind'], severity: args['severity'] || 'normal',
          summary: AgentFeedback.clean(args['summary'], AgentFeedback::SUMMARY_MAX),
          details: AgentFeedback.clean(args['details'], AgentFeedback::DETAILS_MAX, multiline: true),
          related_tool: AgentFeedback.clean(args['related_tool'], 100), related_reference: AgentFeedback.clean(args['related_reference'], 300),
          agent_name: AgentFeedback.clean(args['agent_name'], 100), agent_model: AgentFeedback.clean(args['agent_model'], 100),
          context: args['context'].present? ? JSON.generate(args['context']) : nil
        )
        result("Thank you — feedback ##{feedback.id} (#{feedback.kind_label}) was recorded for the owner. Use list_my_feedback to check its status later.",
          feedback.agent_view)
      rescue ActiveRecord::RecordInvalid => e
        raise ToolError.new("The feedback was not saved: #{e.record.errors.full_messages.to_sentence}.", kind: 'invalid_arguments')
      end

      private

      # Chat and task-opening submissions go through the intake rules: one report
      # per message, "ready" only for allow-listed senders, every action logged.
      def file_intake(args)
        outcome = FeedbackIntake.file!(
          source: args['source'] || 'agent', source_ref: args['source_ref'], source_sender: args['source_sender'], kind: args['kind'],
          summary: args['summary'], details: args['details'], severity: args['severity'], ready: args['ready_for_development'],
          open_task: args['open_task'], agent_name: args['agent_name'] || token.name, user: user, token: token
        )
        feedback = outcome.feedback
        feedback.update_columns(related_tool: AgentFeedback.clean(args['related_tool'], 100), related_reference: AgentFeedback.clean(args['related_reference'], 300),
          agent_model: AgentFeedback.clean(args['agent_model'], 100), context: (JSON.generate(args['context']) if args['context'].present?)) unless outcome.duplicate
        text = "Feedback ##{feedback.id} (#{feedback.kind_label}) #{outcome.duplicate ? 'was already filed' : 'was recorded for review'}" \
               "#{" and task ##{feedback.task_id} opened" if feedback.task_id}. #{FeedbackIntake.report_url(feedback)}"
        text += ' It is NOT marked ready for development: the sender is not on the allow-list or the token lacks tasks:write.' if outcome.ready_denied_reason
        result(text, feedback.reporter_view.merge(ready_for_development: feedback.ready_for_development, ready_denied_reason: outcome.ready_denied_reason))
      rescue FeedbackIntake::Error => e
        raise ToolError.new("The feedback was not saved: #{e.message}", kind: 'invalid_arguments')
      end
    end
  end
end
