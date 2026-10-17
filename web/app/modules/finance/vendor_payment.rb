# frozen_string_literal: true

module Finance
  # A payment made to a vendor against their purchase orders (accounts
  # payable). The vendor's AP balance = received PO value − payments.
  class VendorPayment < ApplicationRecord
    include Discard::Model
    include TenantScoped
    include FinanceAmount
    include LockedPeriodGuard

    self.table_name = 'vendor_payments'

    # Exclude discarded rows by default so they don't count toward balances.
    default_scope { undiscarded }

    METHODS = %w[card cash check bank_transfer ach other].freeze

    belongs_to :vendor, class_name: 'Purchasing::Vendor'

    guard_locked_period :paid_on
    validates :amount_cents, numericality: { greater_than: 0, less_than_or_equal_to: 2_147_483_647 }
    validates :paid_on, presence: true

    scope :since, ->(date) { where('paid_on >= ?', date) }
    scope :recent, ->(limit = 100) { order(paid_on: :desc, created_at: :desc).limit(limit) }
  end
end
