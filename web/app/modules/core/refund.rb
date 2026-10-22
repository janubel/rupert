# frozen_string_literal: true

module Core
  # A refund against a sales order (partial or full). The sum of refunds drives
  # the order's refunded status and the financial report.
  class Refund < ApplicationRecord
    include Discard::Model
    include TenantScoped

    self.table_name = 'refunds'

    # Exclude discarded rows by default so they don't count toward refund totals.
    default_scope { undiscarded }

    METHODS = %w[card cash gift_card check store_credit other].freeze

    belongs_to :order, class_name: 'Core::Order', foreign_key: :order_id, inverse_of: :refunds

    validates :amount_cents, numericality: { greater_than: 0 }
    validates :method, presence: true, inclusion: { in: METHODS }
    validates :refunded_at, presence: true

    scope :recent, ->(limit = 50) { order(refunded_at: :desc).limit(limit) }

    after_commit :sync_ledger

    private

    # See Core::Payment#sync_ledger: reported, never raised, and visible as unposted.
    def sync_ledger
      tenant = self.tenant || Current.tenant
      return unless tenant

      Current.set(tenant: tenant) do
        destroyed? ? Finance::Posting.void_source('Core::Refund', id) : Finance::Posting.sync_refund(self)
      end
    rescue StandardError => e
      Rails.error.report(e, handled: true, context: { refund_id: id, source: 'ledger_refund_posting' })
    end
  end
end
