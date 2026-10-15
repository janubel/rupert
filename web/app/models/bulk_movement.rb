# frozen_string_literal: true

class BulkMovement < ApplicationRecord
  include TenantScoped

  belongs_to :bulk_lot

  attr_accessor :balance_checked, :conversion_error

  attribute :request_token, :string, default: -> { SecureRandom.uuid }

  validates :tenant_id, :reference, :created_by, :input_quantity, :request_token, presence: true
  validates :reference, length: { maximum: 200 }
  validates :request_token, length: { maximum: 100 }
  validates :kind, inclusion: { in: %w[receipt consume adjustment] }
  validates :input_unit, inclusion: { in: BulkMass::FACTORS.keys }
  validates :delta_mg, numericality: { only_integer: true, other_than: 0, greater_than_or_equal_to: -BulkMass::MAX_MG,
    less_than_or_equal_to: BulkMass::MAX_MG }
  validate :valid_conversion
  validate :valid_direction
  validate :lot_belongs_to_tenant
  validate :checked_balance, on: :create

  def readonly?
    persisted? || super
  end

  private

  def valid_conversion
    errors.add(:base, conversion_error) if conversion_error
  end

  def valid_direction
    return unless delta_mg.is_a?(Integer)

    errors.add(:delta_mg, 'must be positive for receipts') if kind == 'receipt' && delta_mg.negative?
    errors.add(:delta_mg, 'must be negative for consumption') if kind == 'consume' && delta_mg.positive?
  end

  def lot_belongs_to_tenant
    return if bulk_lot && bulk_lot.tenant_id == tenant_id

    errors.add(:bulk_lot, 'must belong to the same store')
  end

  def checked_balance
    errors.add(:base, 'Use the bulk ledger service to check remaining material') unless balance_checked
  end
end
