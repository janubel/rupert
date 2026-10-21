# frozen_string_literal: true

module AskRupert
  # Chats are saved until their owner clears them, unless the workspace sets a
  # retention window in days, after which they are deleted with their messages.
  # Run per tenant with Current.tenant set.
  module Retention
    module_function

    def purge!(now: Time.current, config: Config.current)
      Usage.where(created_at: ...(now - Usage::RETAIN)).delete_all
      return 0 if config['retention_days'].zero?

      old = Conversation.where('COALESCE(last_message_at, created_at) < ?', now - config['retention_days'].days)
      removed = old.count
      old.find_each(&:destroy)
      removed
    end
  end
end
