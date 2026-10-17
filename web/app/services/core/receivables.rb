# frozen_string_literal: true

module Core
  # Accounts receivable: what customers still owe us from paid/fulfilled
  # orders, net of completed payments. Part of the Core commerce context
  # (customers, orders, payments) feeding the Finance::AccountsController.
  class Receivables
    class << self
      # Per-customer AR: what's still unpaid across their orders. Two grouped
      # queries (gross per customer, paid per customer) — no per-order
      # correlated subqueries.
      def by_customer
        rows = Core::Customer.joins(:orders)
                             .where(orders: { status: %w[paid fulfilled] })
                             .group('customers.id', 'customers.preferred_name', 'customers.first_name', 'customers.last_name', 'customers.email', 'customers.phone', 'orders.currency')
                             .select(
                               'customers.id',
                               'customers.preferred_name',
                               'customers.first_name',
                               'customers.last_name',
                               'customers.email',
                               'customers.phone',
                               'SUM(orders.gross_cents) AS gross_cents',
                               'COUNT(orders.gross_cents) AS amount_count',
                               'COUNT(orders.id) AS order_count',
                               'orders.currency AS balance_currency'
                             )

        paid_by_customer = Core::Payment.where(status: 'completed')
                                        .joins(:order)
                                        .where(orders: { status: %w[paid fulfilled] })
                                        .group('orders.customer_id', 'orders.currency')
                                        .sum(:amount_cents)

        rows.filter_map do |row|
          paid = paid_by_customer.fetch([row.id, row.balance_currency], 0)
          balance = row.amount_count == row.order_count ? row.gross_cents.to_i - paid : nil
          next if balance && balance <= 0

          {
            customer: row,
            currency: row.balance_currency,
            balance_cents: balance,
            paid_cents: paid,
            order_count: row.order_count
          }
        end.sort_by { |r| [r[:balance_cents].nil? ? 0 : 1, -(r[:balance_cents] || 0)] }
      end

      def total_cents(currency: 'USD')
        rows = by_customer.select { |row| row[:currency] == currency }
        rows.sum { |row| row[:balance_cents] } unless rows.any? { |row| row[:balance_cents].nil? }
      end
    end
  end
end
