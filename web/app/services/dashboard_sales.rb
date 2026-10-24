# frozen_string_literal: true

# A request-local sales view. Never reads payment, invoice, deposit or ledger
# mirrors. Native C-Trax sales remain snapshots, not duplicate canonical orders.
class DashboardSales
  SOURCES = %w[shopify square rupert_pos manual pos].freeze
  LABELS = { 'shopify' => 'Shopify', 'square' => 'Square', 'ctrax' => 'C-Trax', 'swipesimple' => 'SwipeSimple',
             'rupert_pos' => 'Rupert POS', 'manual' => 'Manual', 'pos' => 'POS' }.freeze
  attr_reader :now, :from, :warnings

  def initialize(days: 30, now: Time.current, include_ctrax: true)
    @now = now.in_time_zone
    @from = (@now.to_date - (days - 1)).beginning_of_day
    @warnings = []
    @rows = canonical_rows + (include_ctrax ? ctrax_rows : []) + swipesimple_rows
    @warnings.uniq!
  end

  def rows(since: from, until_time: now, before: nil, source: nil)
    @rows.select { |row| row[:at] >= since && row[:at] <= until_time && (before.nil? || row[:at] < before) && (source.blank? || row[:source] == source) }
  end

  def gross(**options)
    rows(**options).sum { |row| row[:cents] }
  end

  def count(**options)
    rows(**options).size
  end

  def groups(**options)
    rows(**options).group_by { |row| row[:source] }.sort.map do |source, values|
      [source, values.sum { |row| row[:cents] }, values.size]
    end
  end

  def daily(metric: :gross, **options)
    series = (from.to_date..now.to_date).index_with { 0 }
    rows(**options).each do |row|
      series[row[:at].in_time_zone.to_date] += metric == :count ? 1 : row[:cents]
    end
    metric == :count ? series : series.transform_values { |cents| cents / 100.0 }
  end

  def hourly(source: nil)
    series = (0..23).index_with { 0 }
    # SwipeSimple reports whole days only, so it has no hour to sit in.
    rows(source: source).each { |row| series[row[:at].in_time_zone.hour] += row[:cents] unless row[:daily] }
    series.transform_values { |cents| cents / 100.0 }
  end

  private

  def canonical_rows
    Core::Order.where(status: %w[paid fulfilled], occurred_at: from..now, source: SOURCES)
      .pluck(:source, :occurred_at, :gross_cents, :currency).filter_map do |source, at, cents, currency|
      unless cents.is_a?(Integer) && currency == 'USD'
        warnings << 'Sales with missing amounts or a currency other than USD are excluded.'
        next
      end
      { source: source, at: at, cents: cents }
    end
  end

  # SwipeSimple card-terminal sales: one row per merchant account and day ("Total Net Sales" from its sales report).
  # Counted from the start of that day. Accounts are added together; deposits are never counted.
  def swipesimple_rows
    SwipesimpleSalesDay.where(business_date: from.to_date..now.to_date).where.not(net_sales_cents: [nil, 0])
      .pluck(:business_date, :net_sales_cents).map do |date, cents|
      { source: 'swipesimple', at: date.in_time_zone.beginning_of_day, cents: cents, daily: true }
    end
  rescue ActiveRecord::StatementInvalid
    []
  end

  def ctrax_rows
    # Include adjacent store dates for timezones either side of the dashboard's
    # business timezone, then filter actual completion timestamps below.
    snapshots = CtraxDay.where(business_date: (from.to_date - 1)..(now.to_date + 1)).order(:captured_at, :id)
    selected = {}
    snapshots.each do |day|
      day.orders.each do |order|
        next unless order['status'] == 'completed' && !order['deleted']

        key = [day.api_origin.to_s.delete_suffix('/'), day.store_id, order['id']]
        warnings << 'Repeated C-Trax order IDs use the newest stored snapshot once.' if selected.key?(key)
        selected[key] = [day, order]
      end
    end
    selected.values.filter_map do |day, order|
      at = Time.iso8601(order.fetch('completed_at'))
      next unless at >= from && at <= now

      unless order['id'].present? && at.in_time_zone(day.timezone).to_date == day.business_date &&
             order['total'].is_a?(Integer) && day.currency == 'USD'
        warnings << 'C-Trax sales with missing amounts, conflicting dates or non-USD currency are excluded.'
        next
      end
      warnings << 'C-Trax refunds require review in daily close; these are recorded sales before refunds.' if order['refund_count'].to_i.positive?
      { source: 'ctrax', at: at, cents: order['total'] }
    rescue KeyError, ArgumentError
      warnings << 'C-Trax sales with an unreadable completion date are excluded.'
      nil
    end
  rescue ActiveRecord::Encryption::Errors::Decryption
    warnings << 'C-Trax sales are unavailable until the original encryption keys are restored.'
    []
  end
end
