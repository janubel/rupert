# frozen_string_literal: true

module Mcp
  # A plain-language failure the assistant can act on. kind feeds the
  # automatic struggle counter (AgentToolIssue::ERROR_KINDS).
  class ToolError < StandardError
    attr_reader :kind

    def initialize(message, kind: 'tool_error')
      super(message)
      @kind = kind
    end
  end
end
