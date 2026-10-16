# frozen_string_literal: true

class PosStockAllocation < ApplicationRecord
  include TenantScoped
  belongs_to :location
  belongs_to :pos_checkout
  validates :quantity, numericality: { only_integer: true, greater_than: 0 }
  validates :status, inclusion: { in: %w[held pending submitting unknown applied released] }
  def marker = "Rupert POS #{pos_checkout.reference} variant #{variant_id}"
end
