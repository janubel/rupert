# frozen_string_literal: true

module Mcp
  module Tools
    # Shared rules for the read-only operations tools. Process, queue, backup and
    # deploy facts belong to the whole server, not to one store, so they are shown
    # only to a platform administrator, or on a private single-store workspace.
    module OperationsAccess
      private

      def instance_operator?
        user.super_admin? || WorkspaceNode.isolated?
      end

      def require_instance_operator!
        return if instance_operator?

        raise ToolError.new('This information is about the whole Rupert server. Only a platform administrator, or a private ' \
                            'single-store workspace, can read it through MCP.', kind: 'denied')
      end

      # A short, scrubbed, single-line excerpt of text from logs or job errors.
      def excerpt(text, max = 240)
        FeedbackSanitizer.scrub_text(text.to_s.gsub(/\p{Cc}/, ' ').squish, max: max)
      end
    end
  end
end
