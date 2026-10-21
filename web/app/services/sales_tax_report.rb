# frozen_string_literal: true

require 'csv'

# Sales tax collected over any date range, one line per source and store.
# Shopify/Square/Rupert POS come from stored orders, C-Trax from its stored
# store-days, SwipeSimple from its transaction exports (which carry no tax
# figure). When a tax rate is given, sources without a reported tax figure get a
# separate, clearly labelled estimate; reported tax is never replaced.
# Sources are separate lines and are never added into one total, because the
# same card sale can appear in a store and in its processor. Unknown amounts
# stay nil, never zero.
class SalesTaxReport
  MAX_DAYS = 400
  MAX_RATE = 30
  ORDER_SOURCES = { 'shopify' => 'Shopify', 'square' => 'Square', 'rupert_pos' => 'Rupert POS' }.freeze
  # Filter keys offered in the report form, in display order.
  SOURCES = { 'shopify' => 'Shopify', 'square' => 'Square', 'ctrax' => 'C-Trax', 'swipesimple' => 'SwipeSimple',
              'rupert_pos' => 'Rupert POS' }.freeze

  Line = Struct.new(:source, :store, :currency, :orders, :sales_before_tax, :tax_collected, :tax_refunded, :net_tax,
    :gross_sales, :estimated_tax, :note, keyword_init: true)

  class Error < StandardError; end

  attr_reader :from, :to, :sources, :rate

  # sources: optional list of SOURCES keys (nil or empty means every source).
  # rate: optional percent (e.g. 6.35) used only for the estimated-tax column.
  def initialize(from:, to:, sources: nil, rate: nil)
    @from = from
    @to = to
    @sources = Array(sources).map(&:to_s) & SOURCES.keys
    @sources = SOURCES.keys if @sources.empty?
    @rate = parse_rate(rate)
    raise Error, 'The end date must be on or after the start date.' if to < from
    raise Error, "Choose a range of #{MAX_DAYS} days or fewer." if (to - from).to_i >= MAX_DAYS
  end

  def lines
    @lines ||= [order_lines, (ctrax_lines if include?('ctrax')), (swipesimple_lines if include?('swipesimple'))]
      .compact.flatten.sort_by { |line| [line.source, line.store.to_s.downcase, line.currency.to_s] }
  end

  def include?(source)
    sources.include?(source)
  end

  def estimating?
    !rate.nil?
  end

  def csv
    CSV.generate do |csv|
      csv << ['Sales tax report', "From #{from}", "To #{to}"]
      csv << ['Sources', sources.map { |key| SOURCES[key] }.join(' + '), 'Estimate rate', estimating? ? "#{rate.to_s('F')}%" : 'None']
      csv << ['Source', 'Store', 'Currency', 'Orders', 'Gross sales cents', 'Sales before tax cents', 'Tax collected cents', 'Tax refunded cents', 'Net tax cents', 'Estimated tax cents', 'Note']
      lines.each do |line|
        amounts = [line.gross_sales, line.sales_before_tax, line.tax_collected, line.tax_refunded, line.net_tax].map { |v| v.nil? ? 'Unavailable' : v }
        csv << [line.source, line.store, line.currency, line.orders, *amounts, line.estimated_tax || '', line.note]
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
    Line.new(source: source, store: store, currency: currency, orders: orders, gross_sales: total, sales_before_tax: sales, tax_collected: tax,
      tax_refunded: refunded, net_tax: tax && refunded ? tax - refunded : nil, estimated_tax: tax ? nil : estimate(total), note: note)
  end

  # Tax inside a tax-inclusive total at the given rate: total - total / (1 + rate).
  def estimate(inclusive_cents)
    return nil if rate.nil? || inclusive_cents.nil?

    (inclusive_cents - (BigDecimal(inclusive_cents.to_s) / (1 + (rate / 100)))).round(0, BigDecimal::ROUND_HALF_UP).to_i
  end

  def parse_rate(value)
    return nil if value.blank?

    rate = BigDecimal(value.to_s.strip.delete('%'))
    raise Error, "Enter a tax rate between 0 and #{MAX_RATE} percent." unless rate.positive? && rate <= MAX_RATE

    rate
  rescue ArgumentError
    raise Error, "Enter a tax rate between 0 and #{MAX_RATE} percent."
  end

  def order_lines
    order_sources = ORDER_SOURCES.keys & sources
    return [] if order_sources.empty?

    pools = Core::Order.where(status: DailyRegisterSummary::ELIGIBLE_STATUSES, source: order_sources, occurred_at: window)
      .group(:source, :location_id, :currency)
      .pluck(:source, :location_id, :currency, Arel.sql('COUNT(*)'), Arel.sql('SUM(gross_cents)'), Arel.sql('COUNT(gross_cents)'), Arel.sql('SUM(tax_cents)'), Arel.sql('COUNT(tax_cents)'))
    keys = pools.filter_map { |pool| pool[1].presence }.uniq
    # Orders store the source's location ID (externalId); older rows may hold Rupert's own ID.
    names = Location.where(externalId: keys).pluck(:externalId, :name).to_h
    names = Location.where(id: keys - names.keys).pluck(:id, :name).to_h.transform_keys(&:to_s).merge(names) if (keys - names.keys).any?
    pools.map do |source, location, currency, count, gross, gross_count, tax, tax_count|
      build(source: ORDER_SOURCES.fetch(source, source.to_s.humanize), store: names[location.to_s] || location.presence || 'Online', currency: currency, orders: count,
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
      tips = known_sum(group.select { |row| row.transaction_type == 'Sale' }.map(&:tip_cents))
      taxable = sales - refunds.abs - tips.to_i
      Line.new(source: 'SwipeSimple', store: account, currency: currency, orders: group.count { |row| row.transaction_type == 'Sale' },
        gross_sales: sales, sales_before_tax: nil, tax_collected: nil, tax_refunded: nil, net_tax: nil, estimated_tax: estimate(taxable),
        note: "Card sales #{format('%.2f', sales / 100.0)} less refunds #{format('%.2f', refunds.abs / 100.0)} (tax-inclusive#{tips ? '' : ', tips may be included'}). SwipeSimple exports do not report tax, so collected tax is unavailable#{estimating? ? "; the estimate assumes every sale was taxed at #{rate.to_s('F')}%" : ''}.")
    end
  end

  def known_sum(values)
    values.any?(&:nil?) ? nil : values.sum
  end
end
