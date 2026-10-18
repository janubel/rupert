# frozen_string_literal: true

# Local execution ledger. Source observations remain owned by their platforms.
class StockRequest < ApplicationRecord
  include TenantScoped
  belongs_to :source_pool, class_name: 'StockReservationPool'
  belongs_to :destination_pool, class_name: 'StockReservationPool', optional: true
  belongs_to :stock_reservation, optional: true
  has_many :events, class_name: 'StockRequestEvent', dependent: :restrict_with_exception
  attr_accessor :workflow_checked

  attr_readonly :tenant_id, :request_kind, :source_pool_id, :destination_pool_id, :quantity, :reference, :due_on,
    :created_by, :source_location_external_id, :destination_location_external_id

  validates :request_kind, inclusion: { in: %w[transfer backorder] }
  validates :status, inclusion: { in: %w[pending allocated dispatched completed cancelled] }
  validates :quantity, numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: 2_147_483_647 }
  validates :received_quantity, numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: :quantity }
  validates :reference, :created_by, :source_location_external_id, presence: true
  validates :destination_location_external_id, presence: true, if: :transfer?
  validates :reference, length: { maximum: 200 }
  validate do
    errors.add(:base, 'Use the inventory workflow to change this request.') unless workflow_checked
    pools = [source_pool, destination_pool].compact
    errors.add(:base, 'Stock pools must belong to this workspace.') unless pools.all? { |pool| pool.tenant_id == tenant_id }
    if transfer?
      unless destination_pool && source_pool && destination_pool.source == source_pool.source &&
          destination_pool.source_item_id == source_pool.source_item_id && destination_pool.location_id != source_pool.location_id
        errors.add(:base, 'Transfer the same native item between two locations in one source.')
      end
    elsif destination_pool
      errors.add(:base, 'Backorders have one fulfillment location.')
    end
    if stock_reservation && (stock_reservation.tenant_id != tenant_id || stock_reservation.stock_reservation_pool_id != source_pool_id || stock_reservation.quantity != quantity)
      errors.add(:base, 'The reservation must match this request and its stock pool.')
    end
  end

  def transfer?
    request_kind == 'transfer'
  end

  def outstanding_quantity
    quantity - received_quantity
  end
end
