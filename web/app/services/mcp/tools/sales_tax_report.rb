# frozen_string_literal: true

module Mcp
  module Tools
    class SalesTaxReport < Tool
      tool 'sales_tax_report',
        title: 'Sales tax report',
        description: 'Sales tax collected over a date range, one line per source (Shopify, Square, Rupert POS, C-Trax, ' \
                     'SwipeSimple) and store. Lines are never summed across sources because one card sale can appear in a ' \
                     'store and its processor. A null amount means the source does not report it (unknown, not zero). ' \
                     'With rate, sources lacking a tax figure get a clearly labelled estimate. Amounts are integer cents. ' \
                     'Defaults to this month. Same data as the in-app Sales tax report. Read-only.',
        scope: 'reports:read'

      input_schema(
        type: 'object',
        properties: {
          from: DATE_PROPERTY.merge(description: 'First day (inclusive). Default: first of this month.'),
          to: DATE_PROPERTY.merge(description: 'Last day (inclusive). Default: today.'),
          sources: { type: 'array', maxItems: 5, items: { type: 'string', enum: ::SalesTaxReport::SOURCES.keys },
                     description: 'Limit to these sources. Default: all.' },
          rate: { type: 'number', minimum: 0, maximum: ::SalesTaxReport::MAX_RATE,
                  description: 'Optional tax rate percent (e.g. 6.35) for the estimate column only. Default: the workspace setting.' }
        },
        additionalProperties: false
      )

      def call(args)
        from, to = date_range(args, default_from: Date.current.beginning_of_month, max_days: ::SalesTaxReport::MAX_DAYS)
        rate = args.key?('rate') ? args['rate'].to_s : TenantSettings.sales_tax_rate
        report = ::SalesTaxReport.new(from: from, to: to, sources: args['sources'], rate: rate)
        lines = report.lines.map(&:to_h)
        data = { from: from.iso8601, to: to.iso8601, sources: report.sources, estimate_rate_percent: report.rate&.to_s('F'),
                 lines: lines, note: 'Never add lines together across sources. null = not reported by the source.' }
        text = if lines.empty?
          "No sales are stored for #{from} to #{to} and these sources. This does not establish a zero-sales period."
        else
          "Sales tax #{from} to #{to}: " + lines.map { |l| "#{l[:source]} / #{l[:store]}: tax #{money(l[:tax_collected])} #{l[:currency]} on #{l[:orders]} orders#{" (estimated #{money(l[:estimated_tax])})" if l[:estimated_tax]}" }.join('; ') + '.'
        end
        result(text, data)
      rescue ::SalesTaxReport::Error => e
        raise ToolError.new(e.message, kind: 'invalid_arguments')
      end
    end
  end
end
