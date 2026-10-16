# frozen_string_literal: true

class CtraxImageLink < ApplicationRecord
  include TenantScoped
  belongs_to :location
  belongs_to :shopify_product, class_name: 'ShopifyProduct'
  validates :variant_id, presence: true, uniqueness: { scope: %i[tenant_id location_id] }
  validate do
    unless location&.tenant_id == tenant_id && location.source == 'ctrax' && shopify_product&.tenant_id == tenant_id
      errors.add(:base, 'Both catalog records must belong to this workspace.')
    end
  end
end
