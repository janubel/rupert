# frozen_string_literal: true

class BulkRecipe < ApplicationRecord
  include TenantScoped

  belongs_to :bulk_material
  has_many :bulk_consumptions, dependent: :restrict_with_exception
  attr_accessor :grams_per_unit, :definition_checked

  alias_attribute :material_id, :bulk_material_id

  validates :tenant_id, :source_variant_id, :effective_from, :catalog_title, :created_by, presence: true
  validates :source, inclusion: { in: ['shopify'] }
  validates :source_variant_id, length: { maximum: 255 }, format: { with: %r{\Agid://shopify/ProductVariant/[1-9][0-9]*\z} }
  validates :created_by, length: { maximum: 254 }
  validates :catalog_title, length: { maximum: 500 }
  validates :catalog_sku, length: { maximum: 255 }
  validates :version, numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: 2_147_483_647 }
  validates :mg_per_unit, numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: BulkMass::MAX_MG }
  validate :same_tenant_material
  validate :checked_definition, on: :create

  def readonly?
    persisted? || super
  end

  def grams
    BigDecimal(mg_per_unit.to_s) / 1000 if mg_per_unit
  end

  private

  def same_tenant_material
    errors.add(:bulk_material, 'must belong to the same store') unless bulk_material && bulk_material.tenant_id == tenant_id
  end

  def checked_definition
    errors.add(:base, 'Use the recipe service to verify the exact catalog variant') unless definition_checked
  end
end
