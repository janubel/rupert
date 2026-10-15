# frozen_string_literal: true

class BulkMaterial < ApplicationRecord
  include TenantScoped

  has_many :bulk_lots, dependent: :restrict_with_exception

  normalizes :name, with: ->(name) { name.strip }
  validates :tenant_id, :name, presence: true
  validates :name, length: { maximum: 120 }, uniqueness: { scope: :tenant_id }
  validates :unit, inclusion: { in: BulkMass::FACTORS.keys }
end
