# frozen_string_literal: true

class BulkConsumption < ApplicationRecord
  include TenantScoped

  belongs_to :bulk_recipe
  belongs_to :bulk_lot
  belongs_to :bulk_movement
  attr_accessor :consumption_checked

  validates :tenant_id, :source_order_id, :source_line_id, :source_variant_id, :created_by, :request_token, presence: true
  validates :source, inclusion: { in: ['shopify'] }
  validates :source_order_id, :source_line_id, :source_variant_id, length: { maximum: 255 }
  validates :created_by, length: { maximum: 254 }
  validates :request_token, format: { with: /\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/i }
  validates :source_fingerprint, :request_fingerprint, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :quantity, numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: 2_147_483_647 }
  validates :mg_per_unit, :consumed_mg, numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: BulkMass::MAX_MG }
  validate :valid_snapshot
  validate :checked_consumption, on: :create

  def readonly?
    persisted? || super
  end

  private

  def valid_snapshot
    records = [bulk_recipe, bulk_lot, bulk_movement]
    unless records.all? { |record| record && record.tenant_id == tenant_id }
      errors.add(:base, 'Recipe, lot and movement must belong to the same store')
      return
    end
    unless bulk_recipe.source == source && bulk_recipe.source_variant_id == source_variant_id &&
        bulk_recipe.bulk_material_id == bulk_lot.bulk_material_id && bulk_recipe.mg_per_unit == mg_per_unit &&
        bulk_movement.bulk_lot_id == bulk_lot_id && bulk_movement.kind == 'consume' &&
        bulk_movement.delta_mg == -consumed_mg && quantity.is_a?(Integer) && mg_per_unit.is_a?(Integer) &&
        consumed_mg == quantity * mg_per_unit
      errors.add(:base, 'The consumption snapshot does not match the reviewed recipe and ledger movement')
    end
  end

  def checked_consumption
    errors.add(:base, 'Use the reviewed sale consumption service') unless consumption_checked
  end
end
