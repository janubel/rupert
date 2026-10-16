# frozen_string_literal: true

class PosCheckout < ApplicationRecord
  include TenantScoped
  belongs_to :location
  belongs_to :user
  belongs_to :pos_display_session
  belongs_to :pos_session, class_name: 'Sales::PosSession', optional: true
  belongs_to :order, class_name: 'Core::Order', optional: true
  has_many :pos_stock_allocations
  has_many :pos_payment_attempts
  serialize :lines_json, coder: JSON
  encrypts :lines_json
  validates :reference, uniqueness: true
  validates :status, inclusion: { in: %w[ready processing unknown declined paid cancelled] }
  validates :tender, inclusion: { in: %w[cash card] }
  validates :subtotal_cents, :tax_cents, :tip_cents, :total_cents, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate do
    errors.add(:base, 'Checkout belongs to another workspace.') unless [location, user, pos_display_session, pos_session, order].compact.all? { |row| row.tenant_id == tenant_id }
    errors.add(:total_cents, 'must equal subtotal, tax and tip') unless total_cents == subtotal_cents.to_i + tax_cents.to_i + tip_cents.to_i
  end
  def lines = lines_json || []
  def paid? = status == 'paid'
  def unresolved? = %w[processing unknown].include?(status)

  def receipt
    { id: id, reference: reference, status: status, demo: demo?, tender: tender, subtotal_cents: subtotal_cents,
      tax_cents: tax_cents, tip_cents: tip_cents, total_cents: total_cents, cash_received_cents: cash_received_cents,
      change_cents: change_cents, paid_at: paid_at&.iso8601,
      inventory_pending: pos_stock_allocations.where.not(status: %w[applied released]).exists? }
  end
end
