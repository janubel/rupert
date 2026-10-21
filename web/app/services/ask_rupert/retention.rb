# frozen_string_literal: true

module AskRupert
  # Chats are kept for the workspace's retention window (default 30 days) and
  # then deleted with their messages. Run per tenant with Current.tenant set.
  module Retention
    module_function

    def purge!(now: Time.current, config: Config.current)
      cutoff = now - config['retention_days'].days
      old = Conversation.where('COALESCE(last_message_at, created_at) < ?', cutoff)
      removed = old.count
      old.find_each(&:destroy)
      Usage.where(created_at: ...(now - Usage::RETAIN)).delete_all
      removed
    end
  end
end
