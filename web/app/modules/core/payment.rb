# frozen_string_literal: true

module Core
  # Payment tender applied to an order (card, cash, gift card, etc.).
  class Payment < ApplicationRecord
    include TenantScoped

    self.table_name = 'payments'

    METHODS = %w[card cash gift_card check other].freeze

    belongs_to :order, class_name: 'Core::Order', foreign_key: :order_id

    validates :method, presence: true
    validates :amount_cents, numericality: { greater_than: 0 }
    validates :paid_at, presence: true

    scope :completed, -> { where(status: 'completed') }

    # Every creator (POS, warehouse checkout, SwipeSimple and canonical imports)
    # ends here, so the ledger follows the payment without each one remembering.
    after_commit :sync_ledger

    private

    # Posting must never block taking money or an import: a failure (locked
    # period, missing account) is reported and the payment stays unposted,
    # which the finance reports and `finance:sales:backfill` surface.
    def sync_ledger
      tenant = self.tenant || Current.tenant
      return unless tenant

      Current.set(tenant: tenant) do
        destroyed? ? Finance::Posting.void_source('Core::Payment', id) : Finance::Posting.sync_sale(self)
      end
    rescue StandardError => e
      Rails.error.report(e, handled: true, context: { payment_id: id, source: 'ledger_sale_posting' })
    end
  end
end
