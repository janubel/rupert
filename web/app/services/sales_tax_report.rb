# frozen_string_literal: true

require 'csv'

# Sales tax collected over any date range, one line per source and store.
# Shopify/Square/Rupert POS come from stored orders, C-Trax from its stored
# store-days, SwipeSimple from its pulled Reporting → tax CSV (falling back to its
# transaction exports, which carry no tax figure, when no report was pulled; the
# two are never both shown). When a tax rate is given, sources without a reported tax figure get a
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

  # SwipeSimple's own tax report where it has been pulled for any day in the
  # range; the transaction-export line (with its optional estimate) only for
  # accounts with no pulled tax report. The two are never both shown.
  def swipesimple_lines
    coverage = SwipesimpleReportPull.coverage('tax', from, to)
    days = SwipesimpleTaxDay.where(merchant_account: coverage.keys, business_date: from..to).to_a.group_by(&:merchant_account)
    reported = coverage.map { |account, dates| swipesimple_report_line(account, (days[account] || []).select { |day| dates.include?(day.business_date) }, dates) }
    reported + swipesimple_transaction_lines.reject { |line| coverage.key?(line.store) }
  end

  def swipesimple_report_line(account, days, covered)
    split = days.group_by(&:tax_rate_label).sort_by { |label, list| [-(list.first.rate_percent || 0), label] }.map do |label, list|
      before = known_sum(list.map(&:pre_tax_cents))
      tax = known_sum(list.map(&:tax_cents))
      kind = list.any? { |day| day.rate_percent.to_d.positive? || day.tax_cents.to_i.nonzero? } ? 'taxable' : 'not taxed'
      "#{label} (#{kind}): sales before tax #{dollars(before)}, tax #{dollars(tax)}"
    end
    span = (to - from).to_i + 1
    coverage = if covered.size == span
      "SwipeSimple tax reports cover every day in this range; a day without a row had no sales."
    else
      "SwipeSimple tax reports cover #{covered.size} of #{span} days, pulled through #{covered.max}; days without a pulled report are not counted and are not zero."
    end
    Line.new(source: 'SwipeSimple', store: account, currency: 'USD', orders: nil, gross_sales: known_sum(days.map(&:total_cents)),
      sales_before_tax: known_sum(days.map(&:pre_tax_cents)), tax_collected: known_sum(days.map(&:tax_cents)), tax_refunded: nil, net_tax: nil,
      estimated_tax: nil, note: [split.join('; ').presence&.then { |text| "#{text}." }, coverage,
                                 'Reported by SwipeSimple (Reporting → Sales tax); refunded tax is not broken out.'].compact.join(' '))
  end

  def dollars(cents)
    cents.nil? ? 'unavailable' : ActiveSupport::NumberHelper.number_to_delimited(format('%.2f', BigDecimal(cents.to_s) / 100))
  end

  def swipesimple_transaction_lines
    rows = SwipesimpleReportRow.latest.where(swipesimple_exports: { kind: 'transactions' }).where(occurred_at: window).includes(:swipesimple_export)
      .select { |row| row.status == 'Approved' }
    rows.group_by { |row| [row.swipesimple_export.merchant_account, row.swipesimple_export.currency] }.map do |(account, currency), group|
      sales = group.select { |row| row.transaction_type == 'Sale' }.sum(&:amount_cents)
      refunds = group.select { |row| row.transaction_type == 'Refund' }.sum(&:amount_cents)
      tips = known_sum(group.select { |row| row.transaction_type == 'Sale' }.map(&:tip_cents))
      taxable = sales - refunds.abs - tips.to_i
      Line.new(source: 'SwipeSimple', store: account, currency: currency, orders: group.count { |row| row.transaction_type == 'Sale' },
        gross_sales: sales, sales_before_tax: nil, tax_collected: nil, tax_refunded: nil, net_tax: nil, estimated_tax: estimate(taxable),
        note: "Card sales #{format('%.2f', sales / 100.0)} less refunds #{format('%.2f', refunds.abs / 100.0)} (tax-inclusive#{tips ? '' : ', tips may be included'}). No SwipeSimple tax report has been pulled for these dates and transaction exports do not report tax, so collected tax is unavailable#{estimating? ? "; the estimate assumes every sale was taxed at #{rate.to_s('F')}%" : ''}.")
    end
  end

  def known_sum(values)
    values.any?(&:nil?) ? nil : values.sum
  end
end
