# frozen_string_literal: true

module TeamChat
  # Writes one pending @rupert reply, as the person who asked.
  class ReplyJob < ApplicationJob
    queue_as :default
    # In development jobs run inline; run this one in the background so the room
    # shows the reply arriving, as Solid Queue does in production.
    self.queue_adapter = :async if Rails.env.development?

    def perform(reply_id)
      reply = Message.unscoped.find_by(id: reply_id)
      return unless reply&.pending? && reply.assistant?

      Current.tenant = Tenant.find_by(id: reply.tenant_id)
      Current.user = User.find_by(id: reply.meta.to_h['asked_by'])
      Agent.new(Message.find(reply.id)).run
    ensure
      Current.reset
    end
  end
end
