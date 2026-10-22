# frozen_string_literal: true

# Business figures computed once, in Ruby, from Rupert's own data (issue #357), so the MCP tools, the API, team
# chat bots and reports quote the same answer instead of a language model doing arithmetic.
#
# Every metric is per currency (currencies are never added together), takes a period (named preset or from/to),
# and is compared with the period before or the same dates last year, with the change already worked out.
# Orders are Rupert's canonical order store (Shopify, Square, Rupert POS, manual); paid and fulfilled orders
# count as sales. C-Trax and SwipeSimple snapshots are not orders and are never added in. Unknown is not zero.
module Metrics
  COUNTED = %w[paid fulfilled].freeze
  SOURCES = %w[shopify square rupert_pos manual pos].freeze
  COMPARES = %w[previous last_year none].freeze
  PRESETS = %w[today yesterday this_week last_week this_pay_week last_pay_week this_month last_month
               this_quarter last_quarter year_to_date last_year].freeze
  MAX_DAYS = 400

  Definition = Data.define(:key, :title, :unit, :description)

  CATALOG = [
    Definition.new('gross_sales', 'Gross sales', 'money', 'Paid and fulfilled orders, gross, per currency, with each source.'),
    Definition.new('orders', 'Orders', 'count', 'Number of paid and fulfilled orders, per currency, with each source.'),
    Definition.new('average_order_value', 'Average order value', 'money', 'Gross sales divided by orders, per currency.'),
    Definition.new('best_day', 'Best sales day', 'day', 'The day with the highest gross sales in the period (and its orders).'),
    Definition.new('sales_by_source', 'Sales by source', 'share', 'Gross and orders per source and its share of the currency total.'),
    Definition.new('top_products', 'Top products', 'share', 'The ten products with the most revenue, with units and share of product revenue.'),
    Definition.new('refund_rate', 'Refund rate', 'percent', 'Refunds recorded in the period as a percent of gross sales, with the amount and count.')
  ].freeze

  module_function

  def catalog = CATALOG

  def find(key) = CATALOG.find { |metric| metric.key == key.to_s }

  # name: a catalog key. period or from/to: the window. compare: previous | last_year | none. source: one source.
  def call(name, period: nil, from: nil, to: nil, compare: 'previous', source: nil, today: Date.current)
    metric = find(name) or raise ArgumentError, "Unknown metric #{name.to_s.first(40)}. Use one of: #{CATALOG.map(&:key).join(', ')}."
    compare = compare.presence || 'previous'
    raise ArgumentError, "compare must be one of: #{COMPARES.join(', ')}." unless COMPARES.include?(compare)
    raise ArgumentError, "source must be one of: #{SOURCES.join(', ')}." if source.present? && !SOURCES.include?(source)

    window = Window.resolve(period: period, from: from, to: to, today: today)
    other = { 'previous' => window.previous, 'last_year' => window.last_year }[compare]
    now = compute(metric.key, window, source)
    before = compute(metric.key, other, source) if other
    result = { metric: metric.key, title: metric.title, unit: metric.unit, description: metric.description,
               period: window.as_json, source: source.presence, values: now[:values] }
    if other
      result[:compared_with] = other.as_json.merge(kind: compare, values: before[:values])
      result[:change] = change(metric, now[:values], before[:values])
    end
    result[:caveats] = caveats(metric.key, now, source)
    result[:text] = sentence(metric, window, other, compare, result)
    result
  end

  # --- computations ---

  def compute(key, window, source)
    orders = counted(window, source)
    case key
    when 'gross_sales', 'orders', 'average_order_value', 'sales_by_source' then { values: per_currency(orders, key) }
    when 'best_day' then { values: best_day(orders) }
    when 'top_products' then { values: top_products(orders) }
    when 'refund_rate' then { values: refund_rate(orders, window, source) }
    end
  end

  def counted(window, source)
    Core::Order.where(occurred_at: window.times, status: COUNTED, source: source.presence || SOURCES)
  end

  def per_currency(orders, key)
    rows = orders.group(:currency, :source).pluck(:currency, :source, Arel.sql('COUNT(*)'), Arel.sql('SUM(gross_cents)'), Arel.sql('COUNT(gross_cents)'))
    rows.group_by(&:first).sort_by { |currency, _| currency.to_s }.map do |currency, list|
      count = list.sum { |row| row[2] }
      known = list.all? { |row| row[4] == row[2] }
      gross = known ? list.sum { |row| row[3].to_i } : nil
      sources = list.map do |_, source, n, cents, k|
        amount = k == n ? cents.to_i : nil
        { source: source, orders: n, gross_cents: amount, gross: money(amount, currency),
          share_percent: (gross&.positive? && amount ? (amount * 100.0 / gross).round(1) : nil) }
      end.sort_by { |row| -row[:gross_cents].to_i }
      value = case key
              when 'orders' then count
              when 'average_order_value' then (gross / count.to_f).round if gross && count.positive?
              else gross
              end
      { currency: currency, value: value, formatted: (key == 'orders' ? count.to_s : money(value, currency)),
        orders: count, gross_cents: gross, sources: sources }
    end
  end

  def best_day(orders)
    by_currency = Hash.new { |hash, key| hash[key] = Hash.new { |inner, day| inner[day] = [0, 0] } }
    orders.pluck(:currency, :occurred_at, :gross_cents).each do |currency, at, cents|
      day = by_currency[currency][at.in_time_zone.to_date]
      day[0] += cents.to_i
      day[1] += 1
    end
    by_currency.sort_by { |currency, _| currency.to_s }.map do |currency, days|
      date, (cents, count) = days.max_by { |_, (amount, _)| amount }
      { currency: currency, value: date.iso8601, formatted: "#{date.strftime('%A %b %-d, %Y')}: #{money(cents, currency)} from #{count} orders",
        gross_cents: cents, gross: money(cents, currency), orders: count, days_with_sales: days.size }
    end
  end

  def top_products(orders)
    lines = Core::OrderLine.where(order_id: orders.select(:id)).joins(:order)
    lines.group('orders.currency').pluck(Arel.sql('orders.currency'), Arel.sql('SUM(order_lines.line_cents)')).sort_by { |currency, _| currency.to_s }.map do |currency, total|
      top = lines.where(orders: { currency: currency }).group(:name)
                 .pluck(:name, Arel.sql('SUM(order_lines.line_cents)'), Arel.sql('SUM(order_lines.quantity)'))
                 .sort_by { |row| -row[1].to_i }.first(10)
                 .map do |name, cents, units|
                   { name: name, revenue_cents: cents.to_i, revenue: money(cents.to_i, currency), units: units.to_i,
                     share_percent: (total.to_i.positive? ? (cents.to_i * 100.0 / total.to_i).round(1) : nil) }
                 end
      { currency: currency, value: top.first&.dig(:name), formatted: top.first(3).map { |row| "#{row[:name]} (#{row[:revenue]})" }.join(', '),
        products: top }
    end
  end

  def refund_rate(orders, window, source)
    gross = orders.group(:currency).sum(:gross_cents)
    refunds = Core::Refund.joins(:order).where(refunded_at: window.times)
    refunds = refunds.where(orders: { source: source }) if source.present?
    refunded = refunds.group('orders.currency').pluck(Arel.sql('orders.currency'), Arel.sql('COUNT(*)'), Arel.sql('SUM(refunds.amount_cents)')).to_h { |currency, n, cents| [currency, [n, cents.to_i]] }
    (gross.keys | refunded.keys).compact.sort.map do |currency|
      sales = gross[currency].to_i
      count, cents = refunded.fetch(currency, [0, 0])
      rate = sales.positive? ? (cents * 100.0 / sales).round(2) : nil
      { currency: currency, value: rate, formatted: (rate ? "#{rate}%" : 'unknown (no sales)'), refunds: count,
        refunded_cents: cents, refunded: money(cents, currency), gross_cents: sales, gross: money(sales, currency) }
    end
  end

  # --- comparison and wording ---

  def change(metric, now, before)
    return [] unless %w[money count percent].include?(metric.unit)

    now.filter_map do |row|
      prior = before.find { |candidate| candidate[:currency] == row[:currency] }
      value = row[:value]
      old = prior&.dig(:value)
      next { currency: row[:currency], direction: 'unknown' } if value.nil? || old.nil?

      delta = value - old
      entry = { currency: row[:currency], change_amount: delta.is_a?(Float) ? delta.round(2) : delta,
                direction: delta.positive? ? 'up' : (delta.negative? ? 'down' : 'flat'),
                change_percent: (old.to_f.zero? ? nil : (delta * 100.0 / old).round(1)) }
      entry[:formatted] = case metric.unit
                          when 'money' then "#{entry[:direction]} #{money(delta.abs, row[:currency])}#{" (#{signed(entry[:change_percent])}%)" if entry[:change_percent]}"
                          when 'count' then "#{entry[:direction]} #{delta.abs}#{" (#{signed(entry[:change_percent])}%)" if entry[:change_percent]}"
                          else "#{entry[:direction]} #{delta.abs.round(2)} percentage points"
                          end
      entry
    end
  end

  def caveats(key, now, source)
    list = ['Only orders stored in Rupert (Shopify, Square, Rupert POS, manual). C-Trax and SwipeSimple are separate and not added in.']
    list << 'Currencies are separate; never add them together.' if now[:values].size > 1
    list << "Only the #{source} source." if source.present?
    list << 'No stored orders in this period: that does not prove zero sales (a sync may be missing).' if now[:values].empty?
    list << 'Refunds are counted by refund date; some refund sales from an earlier period.' if key == 'refund_rate'
    list
  end

  def sentence(metric, window, other, compare, result)
    return "#{metric.title}, #{window.label} (#{window.from} to #{window.to}): no stored orders." if result[:values].empty?

    parts = result[:values].map do |row|
      change = Array(result[:change]).find { |entry| entry[:currency] == row[:currency] }
      against = other && (compare == 'last_year' ? 'the same dates last year' : "the period before (#{other.from} to #{other.to})")
      "#{row[:formatted]}#{", #{change[:formatted]} vs #{against}" if change && change[:formatted]}"
    end
    "#{metric.title}, #{window.label} (#{window.from} to #{window.to}): #{parts.join('; ')}."
  end

  def money(cents, currency = 'USD')
    return nil if cents.nil?

    amount = ActiveSupport::NumberHelper.number_to_delimited(format('%.2f', cents.abs / 100.0))
    currency.to_s.upcase == 'USD' || currency.blank? ? "#{'-' if cents.negative?}$#{amount}" : "#{'-' if cents.negative?}#{amount} #{currency}"
  end

  def signed(number) = number.to_f.positive? ? "+#{number}" : number.to_s
end
