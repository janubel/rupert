# frozen_string_literal: true

module TeamChat
  # A RubyLLM tool made at run time from one Toolbox definition, so the model
  # sees each Rupert tool under its own name and JSON Schema while the Toolbox
  # keeps the checks, logging and redaction in one place.
  class LlmTool < RubyLLM::Tool
    def self.build(definition, &handler)
      klass = Class.new(self)
      klass.instance_variable_set(:@tool_name, definition.name)
      klass.description(definition.description.to_s)
      klass.parameters(definition.schema.deep_stringify_keys)
      klass.new(handler)
    end

    def initialize(handler)
      super()
      @handler = handler
    end

    def execute(**arguments)
      @handler.call(arguments)
    end
  end
end
