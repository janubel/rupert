# frozen_string_literal: true

module AskRupert
  # A model could not produce a reply. kind: :rate_limited, :unavailable, :timeout or :error.
  # The message is for logs; people see ProviderError.friendly(kind).
  class ProviderError < StandardError
    attr_reader :kind

    FRIENDLY = {
      rate_limited: 'The assistant is busy right now. Give it a minute and ask again. Help (?) and Learn Rupert still work.',
      timeout: 'That took too long to answer. Try a shorter question, or ask again in a moment.',
      unavailable: 'Ask Rupert can’t reach its assistant right now. Help (?) and Learn Rupert still work, and you can report this.',
      error: 'Something went wrong while answering. Try again, or report it so the team can look.'
    }.freeze

    def self.friendly(kind) = FRIENDLY.fetch(kind, FRIENDLY[:error])

    def initialize(message = nil, kind: :error)
      super(message || kind.to_s)
      @kind = kind
    end
  end
end
