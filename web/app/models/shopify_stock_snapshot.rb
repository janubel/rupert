# frozen_string_literal: true

class ShopifyStockSnapshot < ApplicationRecord
  include TenantScoped

  belongs_to :location, class_name: 'Location'
  serialize :records_json, coder: JSON

  validates :shop_domain, :captured_at, presence: true
  validates :location_id, uniqueness: { scope: :tenant_id }
  validate :location_matches_workspace

  def records
    records_json.is_a?(Array) ? records_json : []
  end

  private

  def location_matches_workspace
    return if location && location.tenant_id == tenant_id && location.source == 'shopify'

    errors.add(:location, 'must be a Shopify location in this workspace')
  end
end
