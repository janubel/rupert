# frozen_string_literal: true

# Aggregates all dashboard statistics in one place. Expensive computations are
# cached in DataCache (version-keyed, invalidated on sync / manual mutations);
# cheap counters and the always-live "recent" lists stay fresh per request.
class DashboardPresenter
  # Canonical revenue truth: Core::Order (paid/fulfilled), matching reports.
  # LedgerEntry remains only the raw transaction mirror for the Ledger page.
  PAID_STATUSES = %w[paid fulfilled].freeze

  attr_reader :product_count,
    :variant_count,
    :sku_link_count,
    :open_alerts,
    :stockouts,
    :recent_runs,
    :recent_syncs,
    :recent_alerts

  def initialize(user: nil)
    @user = user
    @product_count = can_read?('inventory.read') ? DataCache.fetch('dashboard/product_count') { ShopifyProduct.count } : 0
    @variant_count = can_read?('inventory.read') ? DataCache.fetch('dashboard/variant_count') { ShopifyVariant.count } : 0
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

  def today_revenue
    return 0 unless can_read?('sales.read')

    @today_revenue ||= DataCache.fetch('dashboard/today_revenue') { today_orders_scope.sum(:gross_cents) }
  end

  def today_orders
    return 0 unless can_read?('sales.read')

    @today_orders ||= DataCache.fetch('dashboard/today_orders') { today_orders_scope.count }
  end

  def today_groups
    return [] unless can_read?('sales.read')

    @today_groups ||= DataCache.fetch('dashboard/today_groups') do
      today_orders_scope.group(:source)
                        .pluck(:source, Arel.sql('SUM("gross_cents") AS gross'), Arel.sql('COUNT(*) AS count'))
    end
  end

  def yesterday_revenue
    return 0 unless can_read?('sales.read')

    @yesterday_revenue ||= DataCache.fetch('dashboard/yesterday_revenue') do
      Core::Order.where(occurred_at: (today_start - 1.day)...today_start, status: PAID_STATUSES).sum(:gross_cents)
    end
  end

  def week_revenue
    return 0 unless can_read?('sales.read')

    @week_revenue ||= DataCache.fetch('dashboard/week_revenue') do
      Core::Order.since(7.days.ago).where(status: PAID_STATUSES).sum(:gross_cents)
    end
  end

  def month_revenue
    return 0 unless can_read?('sales.read')

    @month_revenue ||= DataCache.fetch('dashboard/month_revenue') do
      Core::Order.since(30.days.ago).where(status: PAID_STATUSES).sum(:gross_cents)
    end
  end

  def ledger_groups
    return [] unless can_read?('sales.read')

    @ledger_groups ||= DataCache.fetch('dashboard/ledger_groups') do
      Core::Order.since(30.days.ago).where(status: PAID_STATUSES).group(:source)
                 .pluck(:source, Arel.sql('SUM("gross_cents") AS gross'), Arel.sql('COUNT(*) AS count'))
    end
  end

  # Revenue per day over the last N days, for chartkick line/area charts.
  def revenue_series(days: 30, source: nil)
    return {} unless can_read?('sales.read')

    key = "dashboard/revenue_series/#{days}/#{source || 'all'}"
    DataCache.fetch(key, ttl: 10.minutes) do
      scope = Core::Order.since(days.days.ago)
      scope = scope.where(source: source) if source.present?
      scope.group_by_day(:occurred_at, default_value: 0, range: days.days.ago..Time.current).sum(:gross_cents)
           .transform_values { |cents| (cents / 100.0).round(2) }
    end
  end

  # Sales count per day over the last N days.
  def sales_volume_series(days: 30, source: nil)
    return {} unless can_read?('sales.read')

    key = "dashboard/sales_volume/#{days}/#{source || 'all'}"
    DataCache.fetch(key, ttl: 10.minutes) do
      scope = Core::Order.since(days.days.ago)
      scope = scope.where(source: source) if source.present?
      scope.group_by_day(:occurred_at, default_value: 0, range: days.days.ago..Time.current).count
    end
  end

  # Gross per hour across all days in range — powers the POS daily shape.
  def hourly_series(days: 30, source: nil)
    return {} unless can_read?('sales.read')

    key = "dashboard/hourly_series/#{days}/#{source || 'all'}"
    DataCache.fetch(key, ttl: 10.minutes) do
      scope = Core::Order.since(days.days.ago)
      scope = scope.where(source: source) if source.present?
      scope.group_by_hour_of_day(:occurred_at, range: days.days.ago..Time.current).sum(:gross_cents)
           .transform_values { |cents| (cents / 100.0).round(2) }
    end
  end

  # Gross per channel/source over the last N days.
  def source_breakdown(days: 30)
    return {} unless can_read?('sales.read')

    key = "dashboard/source_breakdown/#{days}"
    DataCache.fetch(key, ttl: 10.minutes) do
      Core::Order.since(days.days.ago).group(:source).sum(:gross_cents)
                 .transform_keys(&:capitalize).transform_values { |cents| cents / 100.0 }
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
    Time.current.beginning_of_day
  end

  def today_orders_scope
    @today_orders_scope ||= Core::Order.where(occurred_at: today_start..Time.current, status: PAID_STATUSES)
  end
end
