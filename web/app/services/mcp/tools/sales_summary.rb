# frozen_string_literal: true

module Mcp
  module Tools
    class SalesSummary < Tool
      SOURCES = %w[shopify square rupert_pos manual pos].freeze
      COUNTED = %w[paid fulfilled].freeze

      tool 'sales_summary',
        title: 'Sales summary',
        description: 'Orders and gross sales from Rupert\'s canonical order store (Shopify, Square, Rupert POS and manual ' \
                     'sales) for a date range, one line per source and currency, plus a per-currency total, refunded ' \
                     'order counts, optional daily series and top products joined to separate stock observations per ' \
                     'platform/location when inventory access is allowed, with open alert IDs when alert access is allowed. ' \
                     'C-Trax and SwipeSimple snapshots are NOT ' \
                     'included (use sales_tax_report for those). Amounts are integer cents. Defaults to the last 30 days. Read-only.',
        scope: 'reports:read'

      input_schema(
        type: 'object',
        properties: {
          from: DATE_PROPERTY.merge(description: 'First day (inclusive), YYYY-MM-DD. Default: 29 days before to.'),
          to: DATE_PROPERTY.merge(description: 'Last day (inclusive), YYYY-MM-DD. Default: today.'),
          source: { type: 'string', enum: SOURCES, description: 'Only this order source.' },
          include_daily: { type: 'boolean', description: 'Add a per-day series (ranges up to 92 days). Default false.' },
          top_products: { type: 'integer', minimum: 0, maximum: 25, description: 'How many top products by revenue to include. Default 10.' }
        },
        additionalProperties: false
      )

      def call(args)
        to = date_arg(args, 'to', Date.current)
        from, to = date_range(args, default_from: to - 29, default_to: to)
        window = from.in_time_zone.beginning_of_day...(to + 1).in_time_zone.beginning_of_day
        scope = Core::Order.where(occurred_at: window, source: args['source'] || SOURCES)
        counted = scope.where(status: COUNTED)

        lines = counted.group(:source, :currency)
          .pluck(:source, :currency, Arel.sql('COUNT(*)'), Arel.sql('SUM(gross_cents)'), Arel.sql('COUNT(gross_cents)'), Arel.sql('SUM(tax_cents)'), Arel.sql('COUNT(tax_cents)'))
          .map do |source, currency, count, gross, gross_count, tax, tax_count|
            { source: source, currency: currency, orders: count, gross_cents: gross_count == count ? gross.to_i : nil,
              tax_cents: tax_count == count ? tax.to_i : nil }
          end.sort_by { |line| [line[:currency].to_s, line[:source]] }
        refunded = scope.where(status: 'refunded').group(:source).count
        totals = lines.group_by { |line| line[:currency] }.map do |currency, group|
          gross = group.map { |line| line[:gross_cents] }
          { currency: currency, orders: group.sum { |line| line[:orders] }, gross_cents: gross.any?(&:nil?) ? nil : gross.sum,
            average_order_cents: gross.any?(&:nil?) || group.sum { |l| l[:orders] }.zero? ? nil : (gross.sum / group.sum { |l| l[:orders] }.to_f).round }
        end

        data = { from: from.iso8601, to: to.iso8601, counted_statuses: COUNTED, lines: lines, totals_by_currency: totals,
                 refunded_orders_by_source: refunded,
                 note: 'Totals add Shopify, Square and Rupert POS orders, which are separate sales. C-Trax/SwipeSimple are excluded.' }
        data[:daily] = daily(counted, from, to) if args['include_daily']
        limit = args.fetch('top_products', 10)
        data[:top_products] = top_products(window, args['source'], limit) if limit.positive?

        text = if lines.empty?
          "No paid or fulfilled orders are stored from #{from} to #{to}. That does not prove there were no sales (a sync may be missing)."
        else
          "#{from} to #{to}: " + totals.map { |t| "#{t[:orders]} orders, #{money(t[:gross_cents])} #{t[:currency]} gross" }.join('; ') +
            '. By source: ' + lines.map { |l| "#{l[:source]} #{l[:orders]} orders #{money(l[:gross_cents])} #{l[:currency]}" }.join(', ') + '.'
        end
        result(text, data)
      end

      private

      def daily(scope, from, to)
        raise ToolError.new('include_daily works for ranges of 92 days or fewer.', kind: 'invalid_arguments') if (to - from).to_i >= 92

        counts = Hash.new { |hash, key| hash[key] = { orders: 0, gross_cents: 0 } }
        scope.pluck(:occurred_at, :gross_cents).each do |at, gross|
          day = counts[at.in_time_zone.to_date.iso8601]
          day[:orders] += 1
          day[:gross_cents] += gross.to_i
        end
        (from..to).map { |date| { date: date.iso8601 }.merge(counts.fetch(date.iso8601, { orders: 0, gross_cents: 0 })) }
      end

      def top_products(window, source, limit)
        orders = Core::Order.where(occurred_at: window, status: COUNTED, source: source || SOURCES).select(:id)
        rows = Core::OrderLine.where(order_id: orders).group(:name, :sku)
          .pluck(:name, :sku, Arel.sql('SUM(line_cents)'), Arel.sql('SUM(quantity)'), Arel.sql('COUNT(DISTINCT order_id)'))
          .sort_by { |row| -row[2].to_i }.first(limit)
        inventory_allowed = user.can?('inventory.read')
        alerts_allowed = user.can?('alerts.read')
        stock = inventory_allowed ? StockEnrichment.for_skus(rows.map { |row| row[1] }, include_alerts: alerts_allowed) : {}
        rows.map do |name, sku, line_cents, units, order_count|
          { name: name, sku: sku, revenue_cents: line_cents.to_i, units: units.to_i, orders: order_count,
            stock: stock.fetch(sku, { available: inventory_allowed, observations: [], low: nil, alerts_available: alerts_allowed }) }
        end
      end
    end
  end
end
