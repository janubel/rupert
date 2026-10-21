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
                     description: 'Optional small JSON object (≤4000 bytes) with structured details, e.g. the arguments you used.' }
        },
        required: %w[kind summary],
        additionalProperties: false
      )

      output_schema(
        type: 'object',
        properties: {
          id: { type: 'integer' }, kind: { type: 'string' }, severity: { type: 'string' }, status: { type: 'string' },
          summary: { type: 'string' }, related_tool: { type: %w[string null] }, submitted_at: { type: 'string' }, updated_at: { type: 'string' }
        },
        required: %w[id kind status summary]
      )

      def call(args)
        recent = AgentFeedback.where(api_access_token_id: token.id, created_at: 24.hours.ago..).count
        raise ToolError.new("This token has sent #{PER_TOKEN_DAILY_LIMIT} feedback items in the last 24 hours. Please wait before sending more.") if recent >= PER_TOKEN_DAILY_LIMIT

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
    end
  end
end
