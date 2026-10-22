# frozen_string_literal: true

# Writes the reply to one pending Ask Rupert message, as the person who asked.
class AskRupertReplyJob < ApplicationJob
  queue_as :chat
  # In development jobs normally run inline; run this one in the background so the
  # panel can show the reply arriving, as it does with Solid Queue in production.
  self.queue_adapter = :async if Rails.env.development?

  def perform(message_id)
    message = AskRupert::Message.unscoped.find_by(id: message_id)
    return unless message&.pending?

    Current.user = message.user
    Current.tenant = message.user.tenant
    AskRupert::Brain.new(AskRupert::Message.find(message.id), config: AskRupert::Config.current).run
  ensure
    Current.reset
  end
end
