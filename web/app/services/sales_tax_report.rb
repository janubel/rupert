# frozen_string_literal: true

require 'csv'

# Sales tax collected over any date range, one line per source and store.
# Shopify/Square come from imported orders, C-Trax from its stored store-days,
# SwipeSimple from its transaction exports (which carry no tax figure).
# Sources are separate lines and are never added into one total, because the
# same card sale can appear in a store and in its processor. Unknown amounts
# stay nil, never zero.
class SalesTaxReport
  MAX_DAYS = 400
  ORDER_SOURCES = %w[shopify square].freeze

  Line = Struct.new(:source, :store, :currency, :orders, :sales_before_tax, :tax_collected, :tax_refunded, :net_tax, :note, keyword_init: true)

  class Error < StandardError; end

  attr_reader :from, :to

  def initialize(from:, to:)
    @from = from
    @to = to
    raise Error, 'The end date must be on or after the start date.' if to < from
    raise Error, "Choose a range of #{MAX_DAYS} days or fewer." if (to - from).to_i >= MAX_DAYS
  end

  def lines
    @lines ||= (order_lines + ctrax_lines + swipesimple_lines).sort_by { |line| [line.source, line.store.to_s.downcase, line.currency.to_s] }
  end

  def csv
    CSV.generate do |csv|
      csv << ['Sales tax report', "From #{from}", "To #{to}"]
      csv << ['Source', 'Store', 'Currency', 'Orders', 'Sales before tax cents', 'Tax collected cents', 'Tax refunded cents', 'Net tax cents', 'Note']
      lines.each do |line|
        csv << [line.source, line.store, line.currency, line.orders, *[line.sales_before_tax, line.tax_collected, line.tax_refunded, line.net_tax].map { |v| v.nil? ? 'Unavailable' : v }, line.note]
          .map { |cell| cell.is_a?(String) && cell.match?(/\A\s*[=+\-@]/) ? "'#{cell}" : cell }
      end
    end
  end

  private

  def window
    from.beginning_of_day...(to + 1).beginning_of_day
  end

  def build(source:, store:, currency:, orders:, total:, tax:, refunded:, note: nil)
    sales = total && tax ? total - tax : nil
    Line.new(source: source, store: store, currency: currency, orders: orders, sales_before_tax: sales, tax_collected: tax,
      tax_refunded: refunded, net_tax: tax && refunded ? tax - refunded : nil, note: note)
  end

  def order_lines
    pools = Core::Order.where(status: DailyRegisterSummary::ELIGIBLE_STATUSES, source: ORDER_SOURCES, occurred_at: window)
      .group(:source, :location_id, :currency)
      .pluck(:source, :location_id, :currency, Arel.sql('COUNT(*)'), Arel.sql('SUM(gross_cents)'), Arel.sql('COUNT(gross_cents)'), Arel.sql('SUM(tax_cents)'), Arel.sql('COUNT(tax_cents)'))
    names = Location.where(id: pools.filter_map { |pool| pool[1].presence }).pluck(:id, :name).to_h
    pools.map do |source, location, currency, count, gross, gross_count, tax, tax_count|
      build(source: source.capitalize, store: names[location] || location.presence || 'Online', currency: currency, orders: count,
        total: gross_count == count ? gross : nil, tax: tax_count == count ? tax : nil, refunded: nil,
        note: 'Tax on refunded orders is not recorded by this source, so refunded tax is unavailable.')
    end
  end

  def ctrax_lines
    CtraxDay.includes(:location).where(business_date: from..to).group_by { |day| [day.location_id, day.currency] }.map do |(_, currency), days|
      orders = days.flat_map { |day| Ctrax::Reconciliation.new(day).orders }
      total = known_sum(orders.map { |order| order['total'] })
      tax = known_sum(orders.map { |order| order['tax'] })
      refunded = known_sum(days.map { |day| refunded_tax(day) })
      build(source: 'C-Trax', store: days.first.location.name, currency: currency, orders: orders.size, total: total, tax: tax, refunded: refunded,
        note: "#{days.size} store-day#{'s' unless days.size == 1} stored in this range; a missing day is not a zero-sales day.")
    end
  end

  def refunded_tax(day)
    taxes = day.controls['refunds_taxes_sum']
    return taxes if taxes

    day.controls['refund_count'] == 0 ? 0 : nil
  end

  def swipesimple_lines
    rows = SwipesimpleReportRow.latest.where(swipesimple_exports: { kind: 'transactions' }).where(occurred_at: window).includes(:swipesimple_export)
      .select { |row| row.status == 'Approved' }
    rows.group_by { |row| [row.swipesimple_export.merchant_account, row.swipesimple_export.currency] }.map do |(account, currency), group|
      sales = group.select { |row| row.transaction_type == 'Sale' }.sum(&:amount_cents)
      refunds = group.select { |row| row.transaction_type == 'Refund' }.sum(&:amount_cents)
      Line.new(source: 'SwipeSimple', store: account, currency: currency, orders: group.count { |row| row.transaction_type == 'Sale' },
        sales_before_tax: nil, tax_collected: nil, tax_refunded: nil, net_tax: nil,
        note: "Card sales #{format('%.2f', sales / 100.0)} less refunds #{format('%.2f', refunds / 100.0)} (tax-inclusive, tips may be included). SwipeSimple exports do not report tax, so tax is unavailable; use the store lines above.")
    end
  end

  def known_sum(values)
    values.any?(&:nil?) ? nil : values.sum
  end
end
