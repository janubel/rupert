# frozen_string_literal: true

module Mcp
  module Tools
    class ListMyFeedback < Tool
      tool 'list_my_feedback',
        title: 'Status of feedback sent with this token',
        description: 'Lists feedback this token has submitted with submit_feedback, newest first, with the owner\'s status ' \
                     '(new, triaged, planned, done, wont_fix). Only this token\'s own submissions are visible. Read-only.'

      input_schema(
        type: 'object',
        properties: {
          status: { type: 'string', enum: AgentFeedback::STATUSES.keys },
          **PAGE_PROPERTIES
        },
        additionalProperties: false
      )

      def call(args)
        scope = AgentFeedback.where(api_access_token_id: token.id).newest_first
        scope = scope.where(status: args['status']) if args['status']
        rows, meta = paginate(scope, args)
        text = rows.empty? ? 'This token has not submitted any matching feedback.' : rows.map { |f| "##{f.id} #{f.status}: #{f.summary}" }.join("\n")
        result(text, { rows: rows.map(&:agent_view), meta: meta })
      end
    end
  end
end
