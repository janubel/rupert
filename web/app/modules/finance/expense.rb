# frozen_string_literal: true

module Finance
  # A money-out record: any business expense (supplies, shipping, labor, rent,
  # etc.). Optionally tied to a vendor.
  class Expense < ApplicationRecord
    include Discard::Model
    include TenantScoped
    include FinanceAmount
    include LockedPeriodGuard

    self.table_name = 'expenses'

    # Exclude discarded rows by default (undiscarded); the ledger/AP queries
    # don't chain .kept, so this keeps deleted records out of the books.
    default_scope { undiscarded }

    CATEGORIES = %w[
      cost_of_goods
      shipping
      labor
      rent
      utilities
      marketing
      software
      supplies
      insurance
      taxes
      other
    ].freeze
    METHODS = %w[card cash check bank_transfer other].freeze

    belongs_to :vendor, class_name: 'Purchasing::Vendor', optional: true
    guard_locked_period :incurred_on

    validates :category, inclusion: { in: CATEGORIES }
    validates :amount_cents, numericality: { greater_than: 0, less_than_or_equal_to: 2_147_483_647 }
    validates :incurred_on, presence: true

    scope :by_category, ->(category) { category.present? && category != 'all' ? where(category: category) : all }
    scope :since, ->(date) { where('incurred_on >= ?', date) }
    scope :recent, ->(limit = 200) { order(incurred_on: :desc, created_at: :desc).limit(limit) }

    def category_label
      category.tr('_', ' ').titleize
    end
  end
end
