# frozen_string_literal: true

module Core
  # Canonical sales order. Fed by the sync engine (Shopify + Square), with
  # POS sessions and manual sales writing here too. `source + source_order_id`
  # is the idempotency key.
  class Order < ApplicationRecord
    include TenantScoped
    include AASM

    self.table_name = 'orders'

    CHANNELS = %w[online pos manual].freeze

    belongs_to :customer, class_name: 'Core::Customer', optional: true
    belongs_to :location, class_name: 'Location', foreign_key: :location_id, primary_key: :externalId, optional: true
    has_many :order_lines, class_name: 'Core::OrderLine', foreign_key: :order_id, dependent: :destroy
    has_many :payments, class_name: 'Core::Payment', foreign_key: :order_id, dependent: :destroy
    has_many :fulfillments, class_name: 'Core::Fulfillment', foreign_key: :order_id, dependent: :destroy
    has_many :refunds, class_name: 'Core::Refund', foreign_key: :order_id, dependent: :destroy

    validates :source, presence: true
    validates :source_order_id, presence: true
    validates :occurred_at, presence: true
    validates :status, presence: true

    scope :recent, ->(limit = 200) { order(occurred_at: :desc).limit(limit) }
    scope :since, ->(date) { where('occurred_at >= ?', date) }
    scope :on_day, ->(date) { where(occurred_at: date.beginning_of_day...date.end_of_day) }
    scope :by_source, ->(source) { source.present? && source != 'all' ? where(source: source) : all }

    aasm column: 'status', no_direct_assignment: true do
      state :placed, initial: true
      state :paid
      state :fulfilled
      state :refunded
      state :cancelled

      event :mark_paid do
        transitions from: :placed, to: :paid
      end
      event :fulfill do
        transitions from: :paid, to: :fulfilled
      end
      event :refund do
        transitions from: %i[paid fulfilled], to: :refunded
      end
      event :cancel do
        transitions from: :placed, to: :cancelled
      end
    end

    # Office fulfillment workflow (optional, off by default): a shipping
    # pipeline independent of the financial status above. Kept as a plain
    # validated column (not AASM) so a second state machine doesn't interfere
    # with the financial status machine's initial state.
    FULFILLMENT_STATUSES = %w[pending in_transition shipped arrived completed].freeze
    FULFILLMENT_ORDER = FULFILLMENT_STATUSES.index_by(&:itself)

    validates :fulfillment_status, inclusion: { in: FULFILLMENT_STATUSES }, allow_nil: true

    def advance_fulfillment_status!(next_status)
      return false unless FULFILLMENT_STATUSES.include?(next_status)

      current = fulfillment_status.presence || 'pending'
      current_index = FULFILLMENT_STATUSES.index(current)
      next_index = FULFILLMENT_STATUSES.index(next_status)
      return false if next_index < current_index

      update!(fulfillment_status: next_status)
      true
    end

    def total_paid_cents
      payments.completed.sum(:amount_cents)
    end

    def total_refunded_cents
      refunds.sum(:amount_cents)
    end

    def refundable_cents
      [total_paid_cents - total_refunded_cents, 0].max
    end

    def balance_due_cents
      [gross_cents + tip_cents.to_i - total_paid_cents, 0].max
    end

    def refunded?
      total_refunded_cents.positive?
    end

    def fully_refunded?
      refundable_cents.zero? && total_refunded_cents.positive?
    end

    # Record a refund (partial or full). When the refunded total reaches the
    # paid total, the order transitions to the refunded financial status.
    # Locked inside a transaction so concurrent refund requests can't over-refund.
    def record_refund!(amount_cents:, method: 'card', reason: nil, reference: nil, refunded_at: Time.current)
      raise ArgumentError, 'amount must be positive' unless amount_cents.to_i.positive?

      transaction do
        with_lock do
          raise ArgumentError, 'refund exceeds paid total' if amount_cents.to_i > refundable_cents

          refund = refunds.create!(
            amount_cents: amount_cents.to_i,
            method: method,
            reason: reason,
            reference: reference,
            refunded_at: refunded_at
          )
          refund! if fully_refunded? && may_refund?
          refund
        end
      end
    end

    def shipping_address
      return if shipping_address1.blank?

      {
        name: shipping_name.presence || customer&.name,
        line1: shipping_address1,
        line2: shipping_address2,
        city: shipping_city,
        province: shipping_province,
        zip: shipping_zip,
        country: shipping_country,
        phone: shipping_phone
      }
    end

    def display_number
      order_number.presence || source_order_id
    end

    def sub_total_cents
      order_lines.sum(:line_cents)
    end
  end
end
