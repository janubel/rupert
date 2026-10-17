# frozen_string_literal: true

require 'csv'

# ERP reporting area. Four report families, all sourced from the canonical
# Core::Order/OrderLine/Payment/Customer store (single source of truth):
#   sales      — revenue trends, channels, locations, top products, AOV
#   financial  — P&L (revenue/tax/refunds), tender breakdown
#   inventory  — stock valuation, movements, low-stock pipeline
#   operations — sync health, reconcile runs, POS cash variance
#
# Every report supports ?days= and ?source= filters, and .csv export.
class ReportsController < AuthenticatedController
  before_action :authorize_reports
  before_action :set_range

  def index
    redirect_to(sales_reports_path)
  end

  def register_summary
    @summary = DailyRegisterSummary.new(day: params[:day].presence || Date.current.iso8601,
      source: params[:source].presence, location_id: params[:location_id].presence)
    respond_to do |format|
      format.html
      format.csv { send_data(@summary.csv, filename: "register-summary-#{@summary.day.iso8601}.csv") }
    end
  rescue ArgumentError
    redirect_to(register_summary_reports_path, alert: 'Choose a valid calendar day (YYYY-MM-DD).')
  end

  def sales
    @days = window_days
    since = @days.days.ago

    payload = DataCache.fetch("reports/sales/#{range_key}", ttl: 10.minutes) do
      {
        revenue_daily: Core::Order.since(since).group_by_day(:occurred_at, range: since..@range_end)
                                  .sum(:gross_cents).transform_values { |c| (c / 100.0).round(2) },
        revenue_weekly: Core::Order.since(since).group_by_week(:occurred_at, range: since..@range_end)
                                   .sum(:gross_cents).transform_values { |c| (c / 100.0).round(2) },
        by_source: Core::Order.since(since).group(:source).sum(:gross_cents)
                              .transform_keys { |k| k.to_s.capitalize }.transform_values { |c| c / 100.0 },
        by_channel: Core::Order.since(since).group(:channel).sum(:gross_cents)
                               .transform_keys { |k| k.to_s.capitalize }.transform_values { |c| c / 100.0 },
        by_location: by_location_totals(since),
        aov: Core::Order.since(since).where(status: %w[paid fulfilled]).average(:gross_cents).to_f / 100.0,
        total_orders: Core::Order.since(since).where(status: %w[paid fulfilled]).count,
        total_revenue: Core::Order.since(since).where(status: %w[paid fulfilled]).sum(:gross_cents) / 100.0,
        top_products: Core::OrderLine.joins(:order)
                                     .where(orders: { occurred_at: since..@range_end })
                                     .group(:name, :sku).sum(:line_cents)
                                     .sort_by { |_, cents| -cents }.first(10)
                                     .map do |(name, sku), cents|
          {
            name: name, sku: sku, revenue: (cents / 100.0).round(2)
          }
        end
      }
    end
    @revenue_daily = payload[:revenue_daily]
    @revenue_weekly = payload[:revenue_weekly]
    @by_source = payload[:by_source]
    @by_channel = payload[:by_channel]
    @by_location = payload[:by_location]
    @aov = payload[:aov]
    @total_orders = payload[:total_orders]
    @total_revenue = payload[:total_revenue]
    @top_products = payload[:top_products]

    respond_to do |format|
      format.html
      format.csv { send_data(sales_csv, filename: "sales-report-#{@days}d.csv") }
    end
  end

  def financial
    since = @range
    orders = Core::Order.since(since).where(status: %w[paid fulfilled])

    payload = DataCache.fetch("reports/financial/#{range_key}", ttl: 10.minutes) do
      revenue_cents = orders.sum(:gross_cents)
      unrecorded_refunds = Core::Order.where(status: 'refunded', occurred_at: since..@range_end)
                                      .where.not(id: Core::Refund.select(:order_id))
      refund_cents = Core::Refund.joins(:order)
                                 .where(orders: { occurred_at: since..@range_end })
                                 .sum('refunds.amount_cents')
      {
        revenue_cents: revenue_cents,
        tax_cents: orders.sum(:tax_cents),
        refund_cents: refund_cents,
        unrecorded_refund_orders: unrecorded_refunds.count,
        unrecorded_refund_cents: unrecorded_refunds.sum(:gross_cents),
        net_cents: revenue_cents,
        avg_order_cents: orders.count.zero? ? 0 : (revenue_cents / orders.count),
        tenders: Core::Payment.joins(:order)
                              .where(orders: { occurred_at: since..@range_end }, payments: { status: 'completed' })
                              .group('payments.method').sum('payments.amount_cents')
                              .transform_values { |c| c / 100.0 },
        daily_net: orders.group_by_day(:occurred_at, range: since..@range_end)
                         .sum(:gross_cents).transform_values { |c| (c / 100.0).round(2) }
      }
    end

    @revenue_cents = payload[:revenue_cents]
    @tax_cents = payload[:tax_cents]
    @refund_cents = payload[:refund_cents]
    @net_cents = payload[:net_cents] - payload[:refund_cents]
    @unrecorded_refund_orders = payload[:unrecorded_refund_orders]
    @unrecorded_refund_cents = payload[:unrecorded_refund_cents]
    @avg_order_cents = payload[:avg_order_cents]
    @tenders = payload[:tenders]
    @daily_net = payload[:daily_net]

    respond_to do |format|
      format.html
      format.csv { send_data(financial_csv, filename: "financial-report-#{@days}d.csv") }
    end
  end

  def inventory
    threshold = TenantSettings.low_stock_threshold_int
    payload = DataCache.fetch("reports/inventory/#{@days}/#{threshold}", ttl: 10.minutes) do
      {
        valuation: ShopifyVariant.where.not(price: nil).where.not(inventoryQuantity: nil)
                                 .sum(Arel.sql('price * "inventoryQuantity"')),
        variants: ShopifyVariant.count,
        tracked: ShopifyVariant.where(tracked: true).count,
        low_stock: ShopifyVariant.where('"inventoryQuantity" > 0 AND "inventoryQuantity" <= ?', threshold).count,
        out_of_stock: ShopifyVariant.where('"inventoryQuantity" <= 0').count,
        movements_30d: InventoryMovement.where('"createdAt" >= ?', 30.days.ago).count,
        movement_trend: InventoryMovement.where('"createdAt" >= ?', 30.days.ago)
                                         .group_by_day(:createdAt, range: 30.days.ago..Time.current).count,
        low_stock_items: ShopifyVariant.includes(:product)
                                       .where('"inventoryQuantity" <= ?', threshold).order(:inventoryQuantity).limit(50)
                                       .map do |v|
          { sku: v.sku, product: v.product&.title, variant: v.title, qty: v.inventoryQuantity,
            price: v.price }
        end
      }
    end
    @valuation = payload[:valuation]
    @variants = payload[:variants]
    @tracked = payload[:tracked]
    @low_stock = payload[:low_stock]
    @out_of_stock = payload[:out_of_stock]
    @movements_30d = payload[:movements_30d]
    @movement_trend = payload[:movement_trend]
    @low_stock_items = payload[:low_stock_items]

    respond_to do |format|
      format.html
      format.csv { send_data(inventory_csv, filename: "inventory-report-#{@days}d.csv") }
    end
  end

  def operations
    @sync_success = SyncRun.where(status: 'success').count
    @sync_failed = SyncRun.where(status: 'failed').count
    @sync_total = SyncRun.count
    @sync_rate = @sync_total.zero? ? 0 : (@sync_success.to_f / @sync_total * 100).round(1)
    @reconcile_runs = ReconcileRun.order(startedAt: :desc).limit(20)
    @reconcile_total = ReconcileRun.count
    @reconcile_success = ReconcileRun.where(status: 'applied').count
    @pos_sessions = Sales::PosSession.order(opened_at: :desc).limit(20)
    @pos_variance_total = Sales::PosSession.where.not(variance_cents: nil).sum(:variance_cents) / 100.0
    @pos_open = Sales::PosSession.where(status: 'open').count

    respond_to do |format|
      format.html
      format.csv { send_data(operations_csv, filename: "operations-report-#{@days}d.csv") }
    end
  end

  def reconciliation
    @reconciliation = ReconciliationReport.new
    respond_to do |format|
      format.html
      format.csv do
        send_data(@reconciliation.csv, filename: "inventory-reconciliation-#{Time.current.to_date.iso8601}.csv")
      end
    end
  end

  private

  def authorize_reports
    authorize(:module, :reports_read?)
  end

  def set_range
    @days = window_days
    @range = @days.days.ago
    @range_end = Time.current
    return unless params[:from].present? || params[:to].present?

    from = parse_date(params[:from]) || @days.days.ago.to_date
    to = parse_date(params[:to]) || Date.today
    from, to = to, from if from > to
    @days = (to - from).to_i.clamp(1, 3650)
    @range = from.beginning_of_day
    @to_date = to
    @range_end = to.end_of_day
  end

  # Orders without a location (all Shopify web orders) used to vanish from the
  # by-location chart because of an inner join; keep them as "Unassigned".
  def by_location_totals(since)
    names = Location.pluck(:externalId, :name).to_h
    Core::Order.since(since).group(:location_id).sum(:gross_cents)
               .each_with_object(Hash.new(0)) do |(external_id, cents), totals|
      totals[external_id.present? ? names.fetch(external_id, 'Unknown location') : 'Unassigned'] += cents / 100.0
    end
  end

  def window_days
    days = params[:days].to_i
    days.zero? ? 30 : days.clamp(7, 365)
  end

  # Cache key that includes the actual date range so two custom ranges with the
  # same day-count never share a cached payload.
  def range_key
    "#{@days}d-#{@range.to_date.iso8601}..#{@range_end.to_date.iso8601}"
  end

  def parse_date(value)
    Date.parse(value)
  rescue ArgumentError, TypeError
    nil
  end

  # --- CSV builders ---

  def sales_csv
    orders = Core::Order.since(@range)
    counts = orders.group_by_day(:occurred_at, range: @range..@range_end).count
    rows = [['Day', 'Revenue (USD)', 'Orders']]
    orders.group_by_day(:occurred_at, range: @range..@range_end).sum(:gross_cents).each do |day, cents|
      rows << [day.iso8601, (cents / 100.0).round(2), counts.fetch(day, 0)]
    end
    to_csv(rows)
  end

  def financial_csv
    rows = [['Metric', 'Value (USD)']]
    rows << ['Gross revenue', @revenue_cents / 100.0]
    rows << ['Tax collected', @tax_cents / 100.0]
    rows << ['Refunds', @refund_cents / 100.0]
    rows << ['Net revenue', @net_cents / 100.0]
    @tenders.each { |method, amt| rows << ["Tender #{method}", amt] }
    to_csv(rows)
  end

  def inventory_csv
    rows = [['SKU', 'Product', 'Variant', 'On hand', 'Price', 'Value']]
    ShopifyVariant.includes(:product).where.not(price: nil).order(:sku).find_each do |v|
      rows << [v.sku, v.product&.title, v.title, v.inventoryQuantity, v.price,
               (v.price.to_f * v.inventoryQuantity.to_i).round(2)]
    end
    to_csv(rows)
  end

  def operations_csv
    rows = [['Sync run', 'Status', 'Started']]
    SyncRun.order(startedAt: :desc).limit(100).each do |run|
      rows << [run.source || run.mode, run.status, run.startedAt]
    end
    to_csv(rows)
  end

  def to_csv(rows)
    CSV.generate do |csv|
      rows.each { |row| csv << row }
    end
  end
end
