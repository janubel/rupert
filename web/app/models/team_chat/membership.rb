# frozen_string_literal: true

module TeamChat
  # Someone in a room, and how far they have read.
  class Membership < ApplicationRecord
    include TenantScoped

    belongs_to :room, class_name: 'TeamChat::Room'
    belongs_to :user

    def hidden? = hidden_at.present?

    def unread_count
      room.messages.visible.top_level.where('id > ?', last_read_message_id).where.not(user_id: user_id).count
    end

    TYPING_FOR = 6.seconds

    def typing!
      update_columns(typing_at: Time.current) if typing_at.nil? || typing_at < 2.seconds.ago
    end

    def mark_read!(message_id)
      return if message_id.to_i <= last_read_message_id

      update_columns(last_read_message_id: message_id.to_i, updated_at: Time.current)
    end
  end
end
