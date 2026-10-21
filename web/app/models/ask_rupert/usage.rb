# frozen_string_literal: true

module AskRupert
  # Counters for one accepted question: who, when, which model, how many tokens.
  # No message text. Feeds the rate limit and the administrator's usage page.
  class Usage < ApplicationRecord
    include TenantScoped

    self.table_name = 'ask_rupert_usages'

    OUTCOMES = %w[pending ok error limited].freeze
    RETAIN = 35.days

    belongs_to :user

    validates :outcome, inclusion: { in: OUTCOMES }

    # Rows that count toward the limits: questions that were answered or are being
    # answered. A reply that failed on our side does not count against anyone.
    scope :accepted, -> { where(outcome: %w[pending ok]) }
    scope :since, ->(time) { where(created_at: time..) }
    scope :for_user, ->(user) { where(user_id: user.id) }

    def total_tokens = tokens_in + tokens_out
  end
end
