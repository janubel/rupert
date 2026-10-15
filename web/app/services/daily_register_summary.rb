# frozen_string_literal: true

require 'csv'

# Completed tenders and refunds use their own event dates. Currencies and
# platform/location pools are never combined. This does not settle a register.
class DailyRegisterSummary
  attr_reader :day, :source, :location_id

  def initialize(day:, source: nil, location_id: nil)
    @day = Date.iso8601(day)
    @source = source
    @location_id = location_id
  end

  def rows
    @rows ||= begin
      result = {}
      sales.group(:currency, :source, :location_id)
           .pluck(:currency, :source, :location_id, Arel.sql('COUNT(*)'), Arel.sql('SUM(gross_cents)'), Arel.sql('SUM(tax_cents)'))
           .each do |currency, platform, location, count, gross, tax|
        row_for(result, currency, platform, location).merge!(orders: count, order_total_cents: gross.to_i, tax_cents: tax.to_i)
      end
      payments.group('orders.currency', 'orders.source', 'orders.location_id', 'payments.method')
              .sum('payments.amount_cents').each do |(currency, platform, location, method), cents|
        row_for(result, currency, platform, location)[:tenders][method] = cents
      end
      refunds.group('orders.currency', 'orders.source', 'orders.location_id')
             .sum('refunds.amount_cents').each do |(currency, platform, location), cents|
        row_for(result, currency, platform, location)[:refund_cents] = cents
      end
      result.values.sort_by { |row| [row[:currency].to_s, row[:source].to_s, row[:location_id].to_s] }
    end
  end

  def missing_payment_orders
    sales.where.not(id: Core::Payment.completed.where.not(order_id: nil).select(:order_id)).count
  end

  def csv
    CSV.generate do |csv|
      csv << ['Day', 'Currency', 'Source', 'Location', 'Paid-status orders', 'Order total cents', 'Recorded tax cents',
        'Cash cents', 'Card cents', 'Gift card cents', 'Other tender cents', 'Recorded refund cents', 'Tenders less refunds cents',
        'Discounts', 'Tips', 'Merchant fees']
      rows.each do |row|
        tenders = row[:tenders]
        other = tenders.except('cash', 'card', 'gift_card').values.sum
        csv << [day.iso8601, csv_text(row[:currency]), csv_text(row[:source]), csv_text(row[:location_id]), row[:orders], row[:order_total_cents],
          row[:tax_cents], tenders.fetch('cash', 0), tenders.fetch('card', 0), tenders.fetch('gift_card', 0), other,
          row[:refund_cents], tenders.values.sum - row[:refund_cents], 'Unavailable', 'Unavailable', 'Unavailable']
      end
    end
  end

  private

  def csv_text(value)
    text = value.to_s
    text.match?(/\A\s*[=+\-@]/) || text.match?(/\A[\t\r]/) ? "'#{text}" : text
  end

  def window
    day.beginning_of_day...(day + 1).beginning_of_day
  end

  def sales
    filter(Core::Order.where(occurred_at: window, status: %w[paid fulfilled refunded]))
  end

  def payments
    filter(Core::Payment.completed.joins(:order).where(paid_at: window).where(orders: { tenant_id: Current.tenant_id }))
  end

  def refunds
    filter(Core::Refund.joins(:order).where(refunded_at: window).where(orders: { tenant_id: Current.tenant_id }))
  end

  def filter(scope)
    scope = scope.where(orders: { source: source }) if source
    scope = scope.where(orders: { location_id: location_id }) if location_id
    scope
  end

  def row_for(result, currency, platform, location)
    result[[currency, platform, location]] ||= {
      currency: currency, source: platform, location_id: location, orders: 0,
      order_total_cents: 0, tax_cents: 0, refund_cents: 0, tenders: {}
    }
  end
end
