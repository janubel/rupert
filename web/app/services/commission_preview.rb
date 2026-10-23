# frozen_string_literal: true

require 'set'

# A read-only estimate, not a payroll posting. Every matching worker receives
# their own 1%; overlapping workers never divide a shared commission pool.
class CommissionPreview
  class Error < StandardError; end
  SOURCES = %w[shopify square swipesimple].freeze
  MAX_ORDERS = 5000
  MAX_SHIFTS = 1000

  attr_reader :gateway_matched_orders, :gateway_excluded_orders, :rows, :eligible_orders, :excluded_orders, :source, :currency, :start_date, :end_date

  # Within a block, the same preview (dates, source, currency) is built once and shared, so the incentive model can
  # ask for many employees over many weeks without recounting the same orders.
  def self.caching
    outer = Thread.current[:commission_preview_cache]
    Thread.current[:commission_preview_cache] ||= {}
    yield
  ensure
    Thread.current[:commission_preview_cache] = outer
  end

  def self.cached(**args)
    store = Thread.current[:commission_preview_cache]
    return new(**args) unless store

    store[args.transform_values(&:to_s)] ||= new(**args)
  end

  def initialize(start_date:, end_date:, source:, currency:)
    @start_date = Date.iso8601(start_date.to_s)
    @end_date = Date.iso8601(end_date.to_s)
    @source = source.to_s
    @currency = currency.to_s.upcase
    unless @end_date >= @start_date && (@end_date - @start_date).to_i < 31 && SOURCES.include?(@source) && @currency.match?(/\A[A-Z]{3}\z/)
      raise Error, 'Choose a window of 1–31 days, one supported source and a three-letter currency.'
    end
    build
  rescue Date::Error
    raise Error, 'Enter valid start and end dates.'
  end

  private

  def build
    from = start_date.in_time_zone.beginning_of_day
    to = (end_date + 1).in_time_zone.beginning_of_day
    orders = Core::Order.where(source: source, currency: currency, status: %w[paid fulfilled])
      .where(occurred_at: from...to).where('gross_cents > 0').order(:occurred_at, :id).limit(MAX_ORDERS + 1).to_a
    shifts = ClockShift.where('started_at < ? AND (ended_at IS NULL OR ended_at > ?)', to, from).limit(MAX_SHIFTS + 1).to_a
    raise Error, 'This preview is too large. Choose a narrower date range.' if orders.length > MAX_ORDERS || shifts.length > MAX_SHIFTS

    ids = orders.map(&:id)
    paid = Core::Payment.completed.where(order_id: ids).group(:order_id).sum(:amount_cents)
    gateway_links = AuthorizeNetSaleLink.active.where(order_id: ids).includes(:order, :authorize_net_transaction).index_by(&:order_id)
    @gateway_matched_orders = gateway_links.size
    @gateway_excluded_orders = 0
    gateway_links.each do |order_id, link|
      eligible = link.eligible_payment?
      @gateway_excluded_orders += 1 unless eligible
      paid[order_id] = eligible ? link.order.gross_cents : 0
    end
    refunds = Core::Refund.where(order_id: ids).distinct.pluck(:order_id).to_set
    bases = Core::OrderLine.where(order_id: ids).where('quantity > 0 AND unit_cents >= 0').group(:order_id).sum('unit_cents * quantity')
    invalid_lines = Core::OrderLine.where(order_id: ids)
      .where('quantity IS NULL OR unit_cents IS NULL OR quantity <= 0 OR unit_cents < 0 OR (unit_cents = 0 AND line_cents > 0)')
      .distinct.pluck(:order_id).to_set
    groups = shifts.group_by(&:employee_key)
    totals = groups.transform_values do |worker_shifts|
      { employee: worker_shifts.max_by(&:started_at).employee_name, employee_id: worker_shifts.first.employee_id,
        employment_type: worker_shifts.first.employment_type, sales_cents: 0, commission_cents: 0, order_count: 0, tip_cents: 0 }
    end
    @eligible_orders = 0
    @excluded_orders = 0
    now = Time.current
    orders.each do |order|
      base = bases[order.id].to_i
      if paid[order.id].to_i < order.gross_cents || refunds.include?(order.id) || invalid_lines.include?(order.id) || base <= 0
        @excluded_orders += 1
        next
      end
      @eligible_orders += 1
      on_shift = groups.select do |_key, intervals|
        intervals.any? { |shift| order.occurred_at >= shift.started_at && order.occurred_at < (shift.ended_at || now) }
      end
      # Commission is never shared; a tip is split evenly between everyone on shift, rounded down.
      tip_share = on_shift.empty? ? 0 : order.tip_cents.to_i / on_shift.size
      on_shift.each_key do |key|
        totals[key][:sales_cents] += base
        totals[key][:commission_cents] += (base + 50) / 100
        totals[key][:order_count] += 1
        totals[key][:tip_cents] += tip_share
      end
    end
    @rows = totals.values.sort_by { |row| row[:employee].downcase }
  end
end
