# frozen_string_literal: true

class WarehousePaymentAttempt < ApplicationRecord
  include TenantScoped

  belongs_to :warehouse_cart
  has_many :warehouse_stock_holds, dependent: :restrict_with_exception
  encrypts :shipping_json
  STATUSES = %w[submitting unknown approved declined paid].freeze
  scope :unresolved, -> { where(status: %w[submitting unknown approved]) }

  validates :status, inclusion: { in: STATUSES }
  validates :invoice_number, :nonce_digest, :gateway_fingerprint, :submitted_at, presence: true
  validates :amount_cents, numericality: { greater_than: 0, only_integer: true }
  validate :cart_in_workspace
  attr_readonly :tenant_id, :warehouse_cart_id, :invoice_number, :nonce_digest, :gateway_fingerprint, :amount_cents, :shipping_json, :submitted_at

  def shipping
    JSON.parse(shipping_json).symbolize_keys
  end

  def readonly?
    super || status_was == 'paid'
  end

  private

  def cart_in_workspace
    errors.add(:warehouse_cart, 'must belong to this workspace') unless warehouse_cart&.tenant_id == tenant_id
  end
end
