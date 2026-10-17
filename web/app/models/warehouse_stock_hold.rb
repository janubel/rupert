# frozen_string_literal: true

class WarehouseStockHold < ApplicationRecord
  include TenantScoped
  belongs_to :warehouse_cart
  belongs_to :warehouse_payment_attempt, optional: true
  belongs_to :order, class_name: 'Core::Order', optional: true
  belongs_to :released_by, class_name: 'User', optional: true
  encrypts :source_adjustment_reference
  scope :held, -> { where(status: 'held') }

  validates :variant_id, presence: true
  validates :quantity, numericality: { only_integer: true, greater_than: 0 }
  validates :status, inclusion: { in: %w[held released] }
  validates :source_adjustment_reference, length: { maximum: 500 }
  validates :released_by, :source_adjustment_reference, :source_adjusted_at, :source_refreshed_at, :fulfillment_confirmed_at, presence: true, if: -> { release_reason == 'fulfilled_source_adjusted' }
  validate do
    errors.add(:base, 'Hold must belong to its cart workspace') unless warehouse_cart&.tenant_id == tenant_id
    if warehouse_payment_attempt && (warehouse_payment_attempt.tenant_id != tenant_id || warehouse_payment_attempt.warehouse_cart_id != warehouse_cart_id)
      errors.add(:base, 'Hold must match its payment attempt')
    end
    errors.add(:base, 'Hold must match its order workspace') if order && (order.tenant_id != tenant_id || order.source_order_id != "wh-#{warehouse_cart_id}")
  end
  attr_readonly :tenant_id, :warehouse_cart_id, :warehouse_payment_attempt_id, :variant_id, :quantity

  def readonly?
    super || status_was == 'released'
  end
end
