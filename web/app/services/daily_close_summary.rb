# frozen_string_literal: true

# One-page daily close figures per store, in the order the owner reads them:
# gross sales, refunds, net sales, collected tax, tips, cash and credit.
#
# Gross sales are what customers were charged for goods AFTER discounts and
# BEFORE tax and tips; discounts are never shown or subtracted separately.
# Each store is its own row and stores are never added together. Missing
# source amounts stay nil (shown as unavailable), never zero.
#
# SwipeSimple is a card processor, so its row describes card money that is
# usually already inside a store's sales. It is shown for comparison only.
class DailyCloseSummary
  CTRAX_CARD_TYPES = %w[credit standaloneCardTerminal].freeze
  STORE_SOURCES = %w[shopify square].freeze

  Row = Struct.new(:label, :kind, :currency, :gross, :refunds, :net, :tax, :tips, :cash, :credit, :notes, :path, keyword_init: true)

  attr_reader :day

  def initialize(day:)
    @day = day.is_a?(Date) ? day : Date.iso8601(day.to_s)
  end

  def store_rows
    @store_rows ||= (ctrax_rows + register_rows).sort_by { |row| [row.label.to_s.downcase] }
  end

  def swipesimple_row
    return @swipesimple_row if defined?(@swipesimple_row)

    totals = SwipesimpleDailyReport.new(day: day.iso8601).totals
    @swipesimple_row = totals.empty? ? nil : build_swipesimple_row(totals)
  end

  def rows
    store_rows + [swipesimple_row].compact
  end

  def empty?
    rows.empty?
  end

  private

  def build_swipesimple_row(totals)
    sales = totals.sum { |row| row[:sale_cents] }
    refunds = totals.sum { |row| row[:refund_cents] }
    tips = totals.all? { |row| row[:sale_tip_cents] } ? totals.sum { |row| row[:sale_tip_cents] } : nil
    Row.new(label: 'SwipeSimple card processor', kind: 'swipesimple', currency: totals.first[:currency], gross: sales, refunds: refunds,
      net: sales - refunds, tax: nil, tips: tips, cash: nil, credit: sales - refunds,
      notes: 'Approved card transactions only. SwipeSimple does not report tax or cash, and these card amounts are normally already inside the store sales above — do not add them.')
  end

  def ctrax_rows
    CtraxDay.includes(:location).where(business_date: day).order(:location_id).map do |snapshot|
      detail = Ctrax::Reconciliation.new(snapshot)
      orders = detail.orders
      payments = detail.payments
      total = detail.sum(orders, 'total')
      tax = detail.sum(orders, 'tax')
      gross = total && tax ? total - tax : nil
      refunds = ctrax_refunds(snapshot)
      Row.new(label: "#{snapshot.location.name} (C-Trax)", kind: 'ctrax', currency: snapshot.currency, gross: gross, refunds: refunds,
        net: gross && refunds ? gross - refunds : nil, tax: tax, tips: detail.sum(orders, 'tip'),
        cash: detail.sum(payments.select { |p| p['type'] == 'cash' }, 'total_amount'),
        credit: detail.sum(payments.select { |p| CTRAX_CARD_TYPES.include?(p['type']) }, 'total_amount'),
        notes: detail.matched? ? nil : 'C-Trax controls do not match; open the day to review.', path: snapshot)
    end
  end

  def ctrax_refunds(snapshot)
    controls = snapshot.controls
    totals = controls['refunds_totals_sum']
    taxes = controls['refunds_taxes_sum']
    return totals - taxes if totals && taxes

    controls['refund_count'] == 0 ? 0 : nil
  end

  def register_rows
    summary = DailyRegisterSummary.new(day: day.iso8601)
    tips = tips_by_pool
    names = Location.where(id: summary.rows.filter_map { |row| row[:location_id].presence }).pluck(:id, :name).to_h
    summary.rows.select { |row| STORE_SOURCES.include?(row[:source]) }.map do |row|
      total = row[:order_total_cents]
      tax = row[:tax_cents]
      gross = total && tax ? total - tax : nil
      refunds = row[:refund_cents]
      Row.new(label: "#{names[row[:location_id]] || row[:location_id].presence || 'Online'} (#{row[:source].capitalize})", kind: row[:source],
        currency: row[:currency], gross: gross, refunds: refunds, net: gross && refunds ? gross - refunds : nil, tax: tax,
        tips: tips[[row[:currency], row[:source], row[:location_id]]] || 0,
        cash: row[:tenders]['cash'] || 0, credit: row[:tenders]['card'] || 0,
        notes: row[:source] == 'shopify' ? 'Shopify cash and card are inferred from each order\'s gateway.' : nil)
    end
  end

  def tips_by_pool
    window = day.beginning_of_day...(day + 1).beginning_of_day
    Core::Order.where(status: DailyRegisterSummary::ELIGIBLE_STATUSES, occurred_at: window, source: STORE_SOURCES)
      .group(:currency, :source, :location_id).sum(:tip_cents)
  end
end
