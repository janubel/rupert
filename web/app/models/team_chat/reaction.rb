# frozen_string_literal: true

module TeamChat
  # One person's emoji on a message.
  class Reaction < ApplicationRecord
    include TenantScoped

    EMOJI = %w[👍 ❤️ 😂 🎉 👀 ✅ 🙏 🔥].freeze

    belongs_to :message, class_name: 'TeamChat::Message', touch: true
    belongs_to :user

    validates :emoji, inclusion: { in: EMOJI }

    # Adds or removes this person's emoji. Returns the message.
    def self.toggle!(message, user, emoji)
      existing = message.reactions.find_by(user_id: user.id, emoji: emoji)
      existing ? existing.destroy! : message.reactions.create!(user: user, emoji: emoji)
      message
    rescue ActiveRecord::RecordNotUnique
      message
    end
  end
end
