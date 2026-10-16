# frozen_string_literal: true

class ReconciliationFollowUpEvent < ApplicationRecord
  include TenantScoped
  encrypts :details_json
  belongs_to :reconciliation_follow_up
  validates :details_json, :tenant_id, presence: true
  validate do
    errors.add(:reconciliation_follow_up, 'must belong to this workspace') unless reconciliation_follow_up&.tenant_id == tenant_id
  end
  before_update { throw :abort }
  before_destroy { throw :abort }

  def details
    JSON.parse(details_json)
  end
end
