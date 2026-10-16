# frozen_string_literal: true

module Sales
  # A POS shift: when a register opened, what it took in, and the cash
  # reconciliation at close. Expected cash = opening float + cash sales; the
  # counted amount is what's physically in the drawer; variance is the diff.
  class PosSession < ApplicationRecord
    include TenantScoped
    include AASM

    self.table_name = 'pos_sessions'

    belongs_to :user, class_name: 'User', optional: true
    belongs_to :location, class_name: 'Location', foreign_key: :location_id, optional: true

    validates :name, presence: true
    validates :opened_at, presence: true
    validates :opening_cash_cents, numericality: { greater_than_or_equal_to: 0 }

    scope :recent, ->(limit = 20) { order(opened_at: :desc).limit(limit) }

    aasm column: 'status', no_direct_assignment: true do
      state :open, initial: true
      state :closed

      event :close do
        transitions from: :open, to: :closed
      end
      event :reopen do
        transitions from: :closed, to: :open
      end
    end

    def cash_sales_cents
      super || 0
    end

    def card_sales_cents
      super || 0
    end

    def gift_sales_cents
      super || 0
    end

    def total_sales_cents
      cash_sales_cents + card_sales_cents + gift_sales_cents
    end

    def expected_cash_cents
      opening_cash_cents + cash_sales_cents
    end

    def variance_cents
      return if counted_cash_cents.nil?

      counted_cash_cents - expected_cash_cents
    end

    # Pull sales for this session's window and location from the canonical
    # order stream, grouped by payment method.
    def refresh_from_orders!
      orders = Core::Order.where('occurred_at >= ?', opened_at)
      orders = orders.where('occurred_at < ?', closed_at) if closed_at
      orders = orders.where(location_id: [location_id, location&.externalId].compact) if location_id.present?

      tenders = orders.joins(:payments).group('payments.method').sum('payments.amount_cents')
      self.cash_sales_cents = tenders['cash'].to_i
      self.card_sales_cents = tenders['card'].to_i
      self.gift_sales_cents = tenders['gift_card'].to_i
      self.expected_cash_cents = expected_cash_cents
      save!
    end

    def settle!(counted_cents: nil, notes: nil)
      self.class.transaction do
        # Use the same store lock as checkout preparation before checking holds.
        Location.where(id: location_id).update_all(active: location.active) if location
        lock!
        raise Pos::Error, 'Finish or cancel outstanding checkouts before closing the register.' if PosCheckout.where(pos_session_id: id, status: %w[ready processing unknown declined]).exists?
        self.counted_cash_cents = counted_cents
        self.notes = notes if notes
        self.variance_cents = variance_cents
        self.closed_at = Time.current
        close!
      end
    end
  end
end
