# frozen_string_literal: true

module Mcp
  # What a tool returns: a short human summary plus structured data.
  Result = Struct.new(:text, :data, keyword_init: true)
end
