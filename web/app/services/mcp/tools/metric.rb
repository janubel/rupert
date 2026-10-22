# frozen_string_literal: true

module Mcp
  module Tools
    # One business figure computed by Rupert (Metrics), with the comparison already worked out, ready to quote.
    class Metric < Tool
      tool 'metric',
        title: 'Metric (a computed business figure)',
        description: 'Returns one business figure computed by Rupert, ready to quote: gross_sales, orders, average_order_value, ' \
                     'best_day, sales_by_source (with shares), top_products (with shares) or refund_rate, per currency, for a ' \
                     'named period or from/to dates, compared with the period before (default) or the same dates last year, ' \
                     'with the change amount, change percent and direction already computed. `sales_by_source` also carries ' \
                     'the latest sync status when the user may read system health. Quote `formatted`, `text` and ' \
                     'the change exactly; never calculate. list_metrics lists them. Read-only.',
        scope: 'reports:read'

      input_schema(
        type: 'object',
        properties: {
          name: { type: 'string', enum: ::Metrics::CATALOG.map(&:key), description: 'Which figure.' },
          period: { type: 'string', enum: ::Metrics::PRESETS, description: 'Named period. Default last_month.' },
          from: DATE_PROPERTY.merge(description: 'Custom first day (instead of period).'),
          to: DATE_PROPERTY.merge(description: 'Custom last day, inclusive.'),
          compare: { type: 'string', enum: ::Metrics::COMPARES, description: 'previous (default), last_year or none.' },
          source: { type: 'string', enum: ::Metrics::SOURCES, description: 'Only this order source.' }
        },
        required: %w[name],
        additionalProperties: false
      )

      def call(args)
        data = ::Metrics.call(args['name'], period: args['period'], from: args['from'], to: args['to'],
          compare: args['compare'], source: args['source'])
        data[:values] = with_sync_status(data[:values]) if args['name'] == 'sales_by_source'
        result(data[:text], data)
      rescue ArgumentError => e
        raise ToolError.new(e.message, kind: 'invalid_arguments')
      end

      private

      def with_sync_status(values)
        sync_tool = Registry.find('sync_health')
        health = sync_tool.new(token: token).call({}).data if sync_tool&.available_to?(token)
        by_source = Array(health&.dig(:channels)).select { |row| row[:feeds].include?('sales') }.index_by { |row| row[:source] }
        Array(values).map do |currency|
          currency.merge(sources: Array(currency[:sources]).map do |source|
            channel = by_source[source[:source]]
            source.merge(sync: channel ? { status: channel[:latest_status] || 'unknown', failing: channel[:failing], last_ok_at: channel[:last_success_at] } :
              { status: (health ? 'unknown' : 'not_available'), failing: nil, last_ok_at: nil })
          end)
        end
      end
    end

    # The figures the metric tool can compute.
    class ListMetrics < Tool
      tool 'list_metrics',
        title: 'List metrics',
        description: 'Lists the business figures Rupert computes (for the metric tool): name, what it means and its unit. Read-only.',
        scope: 'reports:read'

      input_schema(type: 'object', properties: {}, additionalProperties: false)

      def call(_args)
        rows = ::Metrics.catalog.map { |metric| { name: metric.key, title: metric.title, unit: metric.unit, description: metric.description } }
        result("Metrics: #{rows.map { |row| row[:name] }.join(', ')}. Periods: #{::Metrics::PRESETS.join(', ')}; compare: previous, last_year or none.",
          { metrics: rows, periods: ::Metrics::PRESETS, compare: ::Metrics::COMPARES })
      end
    end
  end
end
