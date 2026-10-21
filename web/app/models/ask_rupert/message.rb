# frozen_string_literal: true

module AskRupert
  # One turn. User text and replies are untrusted data wherever they are shown or reused.
  class Message < ApplicationRecord
    include TenantScoped

    self.table_name = 'ask_rupert_messages'

    ROLES = %w[user assistant].freeze
    STATUSES = %w[done pending failed].freeze
    # A reply still pending after this long is treated as failed (a worker died).
    STALE_AFTER = 3.minutes

    belongs_to :conversation, class_name: 'AskRupert::Conversation'
    belongs_to :user

    serialize :links, coder: JSON
    serialize :report_draft, coder: JSON

    validates :role, inclusion: { in: ROLES }
    validates :status, inclusion: { in: STATUSES }

    scope :pending, -> { where(status: 'pending') }

    def assistant? = role == 'assistant'
    def pending? = status == 'pending'

    def stale?
      pending? && created_at < STALE_AFTER.ago
    end

    # What the browser may see. Links and the draft are server-built, never model-supplied.
    def as_payload
      { id: id, role: role, status: status, content: content.to_s, links: Array(links), report_draft: report_draft,
        provider: provider, created_at: created_at.iso8601 }
    end
  end
end
