# frozen_string_literal: true

class CtraxStockSnapshot < ApplicationRecord
  include TenantScoped

  belongs_to :location, class_name: 'Location'
  serialize :records_json, coder: JSON

  validates :tenant_id, :api_origin, :store_id, :captured_at, presence: true
  validates :location_id, uniqueness: { scope: :tenant_id }
  validate :location_matches_workspace

  def records
    records_json.is_a?(Array) ? records_json : []
  end

  private

  def location_matches_workspace
    return if location && location.tenant_id == tenant_id && location.source == 'ctrax'

    errors.add(:location, 'must be a C-Trax location in this workspace')
  end
end
