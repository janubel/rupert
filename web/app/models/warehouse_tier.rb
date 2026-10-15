# frozen_string_literal: true

# A bulk-quantity discount threshold. A nil shareId marks a global default
# tier for the current tenant only; otherwise the tier belongs to one WarehouseShare's custom schedule.
class WarehouseTier < ApplicationRecord
  include HasCuid
  include TenantScoped

  self.table_name = 'WarehouseTier'
  self.primary_key = 'id'

  # The legacy schema uses a camelCase tenantId column (see WarehouseShare).
  alias_attribute :tenant_id, :tenantId
  belongs_to :tenant, optional: true, foreign_key: :tenantId

  belongs_to :share, class_name: 'WarehouseShare', foreign_key: 'shareId', optional: true

  validates :minQty, presence: true, numericality: { only_integer: true, greater_than: 0 }
  validates :discountPercent,
    presence: true,
    numericality: { greater_than_or_equal_to: 0, less_than: 100 }

  def label
    "#{minQty}+ units · #{discountPercent.to_i}% off"
  end
end
