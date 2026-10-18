# frozen_string_literal: true

class StockRequestEvent < ApplicationRecord
  include TenantScoped
  belongs_to :stock_request
  encrypts :reference
  validates :request_token, :payload_digest, :actor, :action, presence: true
  validates :reference, length: { maximum: 500 }
  validate do
    errors.add(:stock_request, 'must belong to this workspace') unless stock_request&.tenant_id == tenant_id
  end

  def readonly?
    persisted? || super
  end
end
