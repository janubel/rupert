# frozen_string_literal: true

class StockReservation < ApplicationRecord
  include TenantScoped

  belongs_to :stock_reservation_pool

  attr_accessor :allocation_checked

  attribute :request_token, :string, default: -> { SecureRandom.uuid }
  attr_readonly :tenant_id, :stock_reservation_pool_id, :quantity, :reference, :expires_at, :created_by, :request_token

  validates :tenant_id, :reference, :created_by, presence: true
  validates :request_token, presence: true, length: { maximum: 100 }
  validates :reference, length: { maximum: 200 }
  validates :quantity, numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: 2_147_483_647 }
  validates :status, inclusion: { in: %w[active released] }
  validate :pool_belongs_to_tenant
  validate :future_expiry, on: :create
  validate :checked_allocation, on: :create

  scope :active_at, ->(at = Time.current) { where(status: 'active').where('expires_at IS NULL OR expires_at > ?', at) }
  scope :recent, -> { order(created_at: :desc, id: :desc) }

  def effective_status(at: Time.current)
    return 'released' if status == 'released'

    expires_at && expires_at <= at ? 'expired' : 'active'
  end

  private

  def pool_belongs_to_tenant
    return if stock_reservation_pool && stock_reservation_pool.tenant_id == tenant_id

    errors.add(:stock_reservation_pool, 'must belong to the same store')
  end

  def future_expiry
    errors.add(:expires_at, 'must be in the future') if expires_at && expires_at <= Time.current
  end

  def checked_allocation
    errors.add(:base, 'Use the reservation service to check available stock') unless allocation_checked
  end
end
