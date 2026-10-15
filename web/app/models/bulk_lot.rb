# frozen_string_literal: true

class BulkLot < ApplicationRecord
  include TenantScoped

  belongs_to :bulk_material
  has_many :bulk_movements, dependent: :restrict_with_exception

  attr_accessor :receipt_checked

  attribute :receipt_token, :string, default: -> { SecureRandom.uuid }
  attr_readonly :tenant_id, :bulk_material_id, :code, :note, :receipt_token, :balance_mg

  normalizes :code, with: ->(code) { code.strip }
  validates :tenant_id, :code, :receipt_token, presence: true
  validates :code, length: { maximum: 120 }
  validates :note, length: { maximum: 500 }
  validates :receipt_token, length: { maximum: 100 }
  validates :balance_mg, numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: BulkMass::MAX_MG }
  validate :material_belongs_to_tenant
  validate :checked_receipt, on: :create

  def serialize_movement
    self.class.transaction do
      # Acquire the writer/row lock before reading balance or replay state.
      self.class.where(id: id).update_all('lock_version = lock_version + 1')
      reload
      yield
    end
  end

  private

  def checked_receipt
    errors.add(:base, 'Use the bulk ledger service to record the initial receipt') unless receipt_checked
  end

  def material_belongs_to_tenant
    return if bulk_material && bulk_material.tenant_id == tenant_id

    errors.add(:bulk_material, 'must belong to the same store')
  end
end
