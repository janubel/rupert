# frozen_string_literal: true

# Aggregates all dashboard statistics in one place. Expensive computations are
# cached in DataCache (version-keyed, invalidated on sync / manual mutations);
# cheap counters and the always-live "recent" lists stay fresh per request.
class DashboardPresenter
  # Sales totals combine canonical orders with native C-Trax completed orders.
  # Payment reports and ledger mirrors never contribute to these totals.

  attr_reader :product_count,
    :variant_count,
    :sku_link_count,
    :open_alerts,
    :stockouts,
    :recent_runs,
    :recent_syncs,
    :recent_alerts

  def initialize(user: nil, include_ctrax: true)
    @user = user
    @include_ctrax = include_ctrax
    @product_count = can_read?('inventory.read') ? DataCache.fetch('dashboard/current_product_count') { ShopifyProduct.active.where(catalog_present: true).count } : 0
    @variant_count = can_read?('inventory.read') ? DataCache.fetch('dashboard/current_variant_count') { ShopifyVariant.current_catalog.count } : 0
    @sku_link_count = can_read?('inventory.read') ? DataCache.fetch('dashboard/sku_link_count') { SkuLink.count } : 0
    @open_alerts = can_read?('alerts.read') ? DataCache.fetch('dashboard/open_alerts') { StockAlert.open.count } : 0
    @stockouts = can_read?('alerts.read') ? DataCache.fetch('dashboard/stockouts') { StockAlert.open.where('quantity <= 0').count } : 0
    @recent_runs = can_read?('reconcile.read') ? ReconcileRun.recent(5) : []
    @recent_syncs = can_read?('sync.read') ? SyncRun.recent(5) : []
    @recent_alerts = can_read?('alerts.read') ? StockAlert.open.order(createdAt: :desc).limit(5) : []
  end

  # --- Cached (version-keyed, invalidated on sync/mutations) ---

  def linked_count
    return 0 unless can_read?('inventory.read')

    @linked_count ||= DataCache.fetch('dashboard/linked_count') { SkuLink.linked.count }
  end

  # Linked pairs whose SKUs disagree — a catalog-identity problem, not a stock
  # problem. Quantity differences between Shopify and Square are normal (two
  # locations, two inventories) and are deliberately not counted anywhere.
  def sku_mismatches
    return 0 unless can_read?('inventory.read')

    @sku_mismatches ||= DataCache.fetch('dashboard/sku_mismatches') do
      links = SkuLink.linked.includes(:square_variation)
      square_skus = links.to_h { |l| [l.id, l.square_variation&.sku.to_s.downcase] }
      links.count { |l| l.sku.to_s.downcase != square_skus[l.id] }
    end
  end

  def sales(days: 30)
    @sales ||= {}
    @sales[days] ||= DashboardSales.new(days: days, now: @now ||= Time.current, include_ctrax: @include_ctrax)
  end

  def sales_warnings
    can_read?('sales.read') ? sales.warnings : []
  end

  def today_revenue
    can_read?('sales.read') ? sales.gross(since: today_start) : 0
  end

  def today_orders
    can_read?('sales.read') ? sales.count(since: today_start) : 0
  end

  def today_groups
    return [] unless can_read?('sales.read')

    # Keep the selling channels visible even on days with no imported sales.
    actual = sales.groups(since: today_start).index_by(&:first)
    (%w[shopify ctrax square] | actual.keys).map { |source| actual.fetch(source, [source, 0, 0]) }
  end

  def yesterday_revenue
    can_read?('sales.read') ? sales.gross(since: today_start - 1.day, before: today_start) : 0
  end

  def week_revenue
    can_read?('sales.read') ? sales.gross(since: today_start - 6.days) : 0
  end

  def month_revenue
    can_read?('sales.read') ? sales.gross : 0
  end

  def ledger_groups
    can_read?('sales.read') ? sales.groups : []
  end

  def revenue_series(days: 30, source: nil)
    can_read?('sales.read') ? sales(days: days).daily(source: source) : {}
  end

  def sales_volume_series(days: 30, source: nil)
    can_read?('sales.read') ? sales(days: days).daily(metric: :count, source: source) : {}
  end

  def hourly_series(days: 30, source: nil)
    can_read?('sales.read') ? sales(days: days).hourly(source: source) : {}
  end

  def source_breakdown(days: 30)
    return {} unless can_read?('sales.read')

    sales(days: days).groups.to_h { |source, cents, _count| [DashboardSales::LABELS.fetch(source, source.humanize), cents / 100.0] }
  end

  def sales_freshness
    return {} unless can_read?('sales.read')

    @sales_freshness ||= begin
      values = Setting.where(key: %w[sync_watermark_shopify sync_watermark_square]).pluck(:key, :value).to_h
      result = %w[shopify square].index_with do |source|
        value = values["sync_watermark_#{source}"]
        { pulled_at: value.present? ? Time.zone.parse(value) : nil,
          latest_sale_at: Core::Order.where(source: source).maximum(:occurred_at) }
      end
      latest_date = CtraxDay.maximum(:business_date)
      result['ctrax'] = { pulled_at: latest_date && CtraxDay.where(business_date: latest_date).minimum(:captured_at),
                          business_date: latest_date }
      result
    end
  end

  def last_sync
    return unless can_read?('sync.read')

    @last_sync ||= SyncRun.order(startedAt: :desc).first
  end

  private

  def can_read?(permission)
    @user.nil? || @user.can?(permission)
  end

  def today_start
    (@now ||= Time.current).beginning_of_day
  end
end
