# frozen_string_literal: true

module Purchasing
  class PurchaseDelivery < ApplicationRecord
    include TenantScoped
    belongs_to :purchase_order
    serialize :quantities_json, coder: JSON
    validates :request_token, :payload_digest, :actor, presence: true
    validate do
      errors.add(:purchase_order, 'must belong to this workspace') unless purchase_order&.tenant_id == tenant_id
    end

    def readonly?
      persisted? || super
    end
  end
end
