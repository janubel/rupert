# frozen_string_literal: true

module TeamChat
  # One person's thumbs up (1) or down (-1) on an assistant reply. The model,
  # engine and agent are copied from the reply so Model scores can compare them.
  class Rating < ApplicationRecord
    include TenantScoped

    VALUES = { 'up' => 1, 'down' => -1 }.freeze

    belongs_to :message, class_name: 'TeamChat::Message', touch: true
    belongs_to :user

    validates :value, inclusion: { in: VALUES.values }

    # Sets this person's rating; the same choice again clears it. Returns the message.
    def self.rate!(message, user, choice)
      value = VALUES.fetch(choice.to_s)
      existing = message.ratings.find_by(user_id: user.id)
      if existing&.value == value
        existing.destroy!
      elsif existing
        existing.update!(value: value)
      else
        meta = message.meta.to_h
        message.ratings.create!(user: user, value: value, agent: meta['agent'].presence || 'rupert', model: meta['model'], engine: meta['engine'])
      end
      message
    rescue ActiveRecord::RecordNotUnique
      message
    end
  end
end
