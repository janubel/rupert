# frozen_string_literal: true

module TeamChat
  # Canonical proposal and receipt. Message JSON is a compatibility projection.
  class Approval < ApplicationRecord
    self.table_name = 'chat_approvals'
    include TenantScoped
    belongs_to :message, class_name: 'TeamChat::Message', optional: true
    has_many :events, class_name: 'TeamChat::ApprovalEvent', foreign_key: :approval_id
    attr_readonly :tenant_id, :source_message_id, :public_id, :proposal, :provenance
    validates :state, inclusion: { in: %w[proposed done failed dismissed] }

    validate :terminal_receipt_immutable, on: :update

    def terminal_receipt_immutable
      errors.add(:base, 'A decided approval is immutable') unless state_in_database == 'proposed'
    end

    def action
      receipt.present? ? receipt : proposal.merge('status' => state)
    end

    def record!(kind, user: nil, details: {})
      events.create!(tenant_id: tenant_id, kind: kind, actor_id: user&.id, actor_name: user&.display_name, details: details)
    end
  end
end
