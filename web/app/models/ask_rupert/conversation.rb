# frozen_string_literal: true

module AskRupert
  # One person's chat with Ask Rupert. Only its owner can read it; Clear deletes it.
  class Conversation < ApplicationRecord
    include TenantScoped

    self.table_name = 'ask_rupert_conversations'

    belongs_to :user
    has_many :messages, -> { order(:id) }, class_name: 'AskRupert::Message', dependent: :destroy

    scope :owned_by, ->(user) { where(user_id: user.id) }
    scope :recent_first, -> { order(Arel.sql('COALESCE(last_message_at, created_at) DESC'), id: :desc) }

    def self.latest_for(user)
      owned_by(user).recent_first.first
    end

    def touch_last_message!
      update_columns(last_message_at: Time.current, updated_at: Time.current)
    end
  end
end
