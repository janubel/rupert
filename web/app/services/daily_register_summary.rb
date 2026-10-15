# frozen_string_literal: true

require 'csv'

# Recorded tender/refund event dates and order dates are intentionally distinct.
# Currencies and platform/location pools are never combined; this is not settlement.
class DailyRegisterSummary
  ELIGIBLE_STATUSES = %w[paid fulfilled refunded].freeze
  KNOWN_SOURCES = %w[shopify square swipesimple].freeze
  FULL_SYNC_HISTORY_LIMIT = 100
  POOL_COLUMNS = %w[orders.currency orders.source orders.location_id].freeze
  COVERAGE_KEYS = %i[missing_payment_orders incomplete_payment_orders overcovered_payment_orders unknown_amount_orders].freeze

  attr_reader :day, :source, :location_id, :generated_at

  def initialize(day:, source: nil, location_id: nil)
    @day = Date.iso8601(day)
    @source = source
    @location_id = location_id
    @generated_at = Time.current
  end

  def rows
    @rows ||= begin
      result = {}
      sales.group(*POOL_COLUMNS).pluck(*POOL_COLUMNS, Arel.sql('COUNT(*)'), Arel.sql('SUM(gross_cents)'),
        Arel.sql('COUNT(gross_cents)'), Arel.sql('SUM(tax_cents)'), Arel.sql('COUNT(tax_cents)')).each do |currency, platform, location, count, gross, gross_count, tax, tax_count|
        row_for(result, currency, platform, location).merge!(orders: count,
          order_total_cents: gross_count == count ? gross : nil, tax_cents: tax_count == count ? tax : nil,
          missing_tax_orders: count - tax_count)
      end
      add_tenders(result, payments, 'payments', :tenders)
      add_tenders(result, refunds, 'refunds', :refund_tenders)
      add_coverage(result)
      add_scope_counts(result)
      result.each_value do |row|
        row[:refund_cents] = known_sum(row[:refund_tenders].values)
        row[:net_tenders] = (row[:tenders].keys | row[:refund_tenders].keys).to_h do |method|
          received = row[:tenders].fetch(method, 0)
          returned = row[:refund_tenders].fetch(method, 0)
          [method, received && returned ? received - returned : nil]
        end
        row[:net_tender_cents] = known_sum(row[:net_tenders].values)
      end
      result.values.sort_by { |row| [row[:currency].to_s, row[:source].to_s, row[:location_id].to_s] }
    end
  end

  def coverage
    @coverage ||= (COVERAGE_KEYS + %i[missing_tax_orders excluded_payment_records missing_order_timestamps missing_payment_timestamps missing_refund_timestamps]).to_h do |key|
      [key, rows.sum { |row| row[key] }]
    end
  end

  def missing_payment_orders
    coverage[:missing_payment_orders]
  end

  # Completion is current import history, not proof the selected day is complete.
  # Full sync details must positively identify the source; Square can be skipped.
  def source_freshness
    @source_freshness ||= begin
      sources = source ? [source] : KNOWN_SOURCES
      successes = SyncRun.where(status: 'success').where.not(finishedAt: nil)
      full_runs = successes.where(source: 'all').order(finishedAt: :desc).limit(FULL_SYNC_HISTORY_LIMIT + 1).to_a
      inspected = full_runs.first(FULL_SYNC_HISTORY_LIMIT)
      latest_events = {
        order_at: eligible_orders.group(:source).maximum(:occurred_at),
        payment_at: payment_scope.group('orders.source').maximum(:paid_at),
        refund_at: refund_scope.group('orders.source').maximum(:refunded_at)
      }
      sources.to_h do |platform|
        direct = successes.where(source: platform).order(finishedAt: :desc).first
        full = inspected.find { |run| full_run_includes?(run, platform) }
        latest = [direct, full].compact.max_by(&:finishedAt)
        limited = full_runs.length > FULL_SYNC_HISTORY_LIMIT && full.nil? &&
          (direct.nil? || direct.finishedAt < inspected.last.finishedAt)
        [platform, { finished_at: latest&.finishedAt, started_at: latest&.startedAt, mode: latest&.mode,
          history_limited: limited }.merge(latest_events.transform_values { |values| values[platform] })]
      end
    end
  end

  def csv
    CSV.generate do |csv|
      csv << ['Day', 'Currency', 'Source', 'Location', 'Paid-status orders', 'Order total cents', 'Recorded tax cents',
        'Cash cents', 'Card cents', 'Gift card cents', 'Other tender cents', 'Recorded refund cents', 'Tenders less refunds cents',
        'Discounts', 'Tips', 'Merchant fees', 'Cash refund cents', 'Card refund cents', 'Gift card refund cents', 'Other tender refund cents',
        'Net cash cents', 'Net card cents', 'Net gift card cents', 'Net other tender cents',
        'Missing payment orders', 'Incomplete payment orders', 'Overcovered payment orders', 'Unknown amount orders', 'Missing tax orders',
        'Excluded unsettled payment records', 'Missing stored order timestamps (all dates)', 'Missing stored payment timestamps (all dates)',
        'Missing stored refund timestamps (all dates)', 'Latest source import completion', 'Import mode', 'Import history coverage',
        'Latest stored eligible order event', 'Latest stored eligible payment event', 'Latest stored refund event', 'Tender provenance', 'Report generated at', 'Day timezone']
      rows.each { |row| csv << csv_row(row) }
    end
  end

  private

  def csv_row(row)
    freshness = source_freshness[row[:source]] || {}
    [day.iso8601, csv_text(row[:currency]), csv_text(row[:source]), csv_text(row[:location_id]), row[:orders],
      csv_amount(row[:order_total_cents]), csv_amount(row[:tax_cents]), *tender_columns(row[:tenders]), row[:refund_cents],
      csv_amount(row[:net_tender_cents]), 'Unavailable', 'Unavailable', 'Unavailable', *tender_columns(row[:refund_tenders]),
      *tender_columns(row[:net_tenders]), *COVERAGE_KEYS.map { |key| row[key] }, row[:missing_tax_orders], row[:excluded_payment_records],
      row[:missing_order_timestamps], row[:missing_payment_timestamps], row[:missing_refund_timestamps],
      freshness[:finished_at]&.iso8601 || 'Unavailable', csv_text(freshness[:mode]),
      freshness_history_label(freshness),
      *%i[order_at payment_at refund_at].map { |key| freshness[key]&.iso8601 || 'Unavailable' },
      row[:source] == 'shopify' ? 'Inferred gateway/order-total tender; timestamp may be order creation' : 'Recorded imported/local tender; not settlement',
      generated_at.iso8601, csv_text(Time.zone.name)]
  end

  def freshness_history_label(freshness)
    return 'Older full-sync history not checked; latest source success unconfirmed' if freshness[:history_limited]

    freshness[:finished_at] ? 'Source-confirmed recorded history' : 'No source-confirmed successful import recorded'
  end

  def tender_columns(tenders)
    %w[cash card gift_card].map { |method| csv_amount(tenders.fetch(method, 0)) } +
      [csv_amount(known_sum(tenders.except('cash', 'card', 'gift_card').values))]
  end

  def csv_amount(value)
    value.nil? ? 'Unavailable' : value
  end

  def csv_text(value)
    text = value.to_s
    text.match?(/\A\s*[=+\-@]/) || text.match?(/\A[\t\r]/) ? "'#{text}" : text
  end

  def known_sum(values)
    values.any?(&:nil?) ? nil : values.sum
  end

  def add_tenders(result, scope, table, key)
    scope.group(*POOL_COLUMNS, "#{table}.method")
         .pluck(*POOL_COLUMNS, "#{table}.method", Arel.sql('COUNT(*)'), Arel.sql("COUNT(#{table}.amount_cents)"),
           Arel.sql("SUM(#{table}.amount_cents)")).each do |currency, platform, location, method, count, known, cents|
      row_for(result, currency, platform, location)[key][method] = count == known ? cents : nil
    end
  end

  # One aggregate join, rather than loading every order or querying each order.
  # Lifetime imported payments are a reconciliation diagnostic, not day-close cash.
  def add_coverage(result)
    totals = Core::Payment.completed.where(order_id: sales.select(:id)).group(:order_id)
                          .select('order_id, COUNT(*) AS payment_count, SUM(amount_cents) AS paid_cents, COUNT(amount_cents) AS known_count, MIN(amount_cents) AS minimum_cents')
    comparison = sales.joins("LEFT JOIN (#{totals.to_sql}) register_payments ON register_payments.order_id = orders.id")
    missing = 'register_payments.payment_count IS NULL'
    unknown = 'orders.gross_cents IS NULL OR orders.gross_cents < 0 OR register_payments.known_count < register_payments.payment_count OR register_payments.minimum_cents <= 0'
    expressions = [missing,
      "NOT (#{missing}) AND NOT (#{unknown}) AND register_payments.paid_cents < orders.gross_cents",
      "NOT (#{missing}) AND NOT (#{unknown}) AND register_payments.paid_cents > orders.gross_cents",
      "NOT (#{missing}) AND (#{unknown})"]
    comparison.group(*POOL_COLUMNS).pluck(*POOL_COLUMNS, *expressions.map { |condition| Arel.sql("SUM(CASE WHEN #{condition} THEN 1 ELSE 0 END)") })
              .each do |currency, platform, location, *counts|
      row_for(result, currency, platform, location).merge!(COVERAGE_KEYS.zip(counts).to_h)
    end
  end

  def add_scope_counts(result)
    scopes = {
      excluded_payment_records: filter(Core::Payment.completed.joins(:order).where(paid_at: window)
        .where(orders: { tenant_id: Current.tenant_id }).where.not(orders: { status: ELIGIBLE_STATUSES })),
      missing_order_timestamps: eligible_orders.where(occurred_at: nil),
      missing_payment_timestamps: payment_scope.where(paid_at: nil),
      missing_refund_timestamps: refund_scope.where(refunded_at: nil)
    }
    scopes.each do |key, scope|
      scope.group(*POOL_COLUMNS).count.each do |(currency, platform, location), count|
        row_for(result, currency, platform, location)[key] = count
      end
    end
  end

  def full_run_includes?(run, platform)
    return false unless %w[shopify square].include?(platform)

    details = JSON.parse(run.details.to_s)
    evidence = details.is_a?(Hash) ? details[platform] : nil
    return false unless evidence.is_a?(Hash) && [nil, 'success'].include?(evidence['status'])

    platform == 'shopify' ? evidence['products'].is_a?(Numeric) && evidence['variants'].is_a?(Numeric) : evidence['orders'].is_a?(Numeric)
  rescue JSON::ParserError
    false
  end

  def window
    day.beginning_of_day...(day + 1).beginning_of_day
  end

  def eligible_orders
    filter(Core::Order.where(status: ELIGIBLE_STATUSES))
  end

  def sales
    eligible_orders.where(occurred_at: window)
  end

  def payment_scope
    filter(Core::Payment.completed.joins(:order).where(orders: { tenant_id: Current.tenant_id, status: ELIGIBLE_STATUSES }))
  end

  def payments
    payment_scope.where(paid_at: window)
  end

  def refund_scope
    filter(Core::Refund.joins(:order).where(orders: { tenant_id: Current.tenant_id }))
  end

  def refunds
    refund_scope.where(refunded_at: window)
  end

  def filter(scope)
    scope = scope.where(orders: { source: source }) if source
    scope = scope.where(orders: { location_id: location_id }) if location_id
    scope
  end

  def row_for(result, currency, platform, location)
    result[[currency, platform, location]] ||= {
      currency: currency, source: platform, location_id: location, orders: 0,
      order_total_cents: 0, tax_cents: 0, refund_cents: 0, tenders: {}, refund_tenders: {},
      missing_payment_orders: 0, incomplete_payment_orders: 0, overcovered_payment_orders: 0, unknown_amount_orders: 0,
      missing_tax_orders: 0, excluded_payment_records: 0, missing_order_timestamps: 0, missing_payment_timestamps: 0, missing_refund_timestamps: 0
    }
  end
end
