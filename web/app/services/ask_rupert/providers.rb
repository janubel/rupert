# frozen_string_literal: true

module AskRupert
  # Which model answers. A provider answers a whole conversation turn:
  #   complete(system:, messages:) { |text_so_far| ... } => Reply
  # `cloud?` providers send text to a third party; the panel says so.
  module Providers
    Reply = Struct.new(:text, :tokens_in, :tokens_out, :provider, :model, keyword_init: true)

    SIMPLE_TURN_MAX = 160
    DATA_WORDS = /\b(sales?|revenue|report|how many|how much|total|orders?|customers?|stock level|on hand|low stock|alerts?|hours worked)\b/i

    module_function

    # Providers to try for this turn, in order. Local-only never falls back to the cloud.
    def for_turn(config, text, local: Ollama.new(config), cloud: Opencode.new)
      case config.mode
      when 'local_only' then [local]
      when 'auto' then simple_turn?(text) && local.configured? ? [local, cloud] : [cloud]
      else [cloud]
      end
    end

    # A short how-to or where-is question, not a numbers question.
    def simple_turn?(text)
      text.to_s.length <= SIMPLE_TURN_MAX && !text.to_s.match?(/\d/) && !text.to_s.match?(DATA_WORDS)
    end

    # What the panel tells people about where their words go.
    def disclosure(config)
      case config.mode
      when 'local_only' then 'Answers come from a model running on this Rupert server. Your questions stay on it.'
      when 'auto' then "Short how-to questions may be answered by a model on this Rupert server; the rest, and any backup, use a cloud AI model (#{Opencode.new.model} through OpenCode). What you ask, and the Rupert pages and records it looks up, are sent to that service."
      else "Answers are written by a cloud AI model (#{Opencode.new.model} through OpenCode). What you ask, and the Rupert pages and records it looks up, are sent to that service. Secrets and customer contact details are removed first."
      end
    end
  end
end
