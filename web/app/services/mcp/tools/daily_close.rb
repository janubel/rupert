# frozen_string_literal: true

module Mcp
  module Tools
    # "How much did the store make?" The in-person registers, the same figures as the Daily close page
    # (DailyCloseSummary): each store on its own row (SwipeSimple register, C-Trax stores, Shopify and Square
    # registers), never added together. sales_summary and metric cover online orders, Square and Rupert POS
    # only and never include the SwipeSimple or C-Trax registers.
    class DailyClose < Tool
      MAX_DAYS = 31
      MEASURES = %i[gross refunds net tax tips cash credit].freeze

      tool 'daily_close',
        title: 'Store daily close',
        description: 'In-person store sales from the registers, the same figures as the Daily close page: one row per store ' \
                     '(the SwipeSimple register, C-Trax stores, and the Shopify and Square registers) with gross sales (after ' \
                     'discounts, before tax and tips), refunds, net sales, tax collected, tips, cash and card. Use it for "how ' \
                     'much did the store make", register, takings, cash, card or tips questions. Stores are never added ' \
                     'together. A null amount is unknown, not zero; a store with no day stored is missing, not a zero day. ' \
                     'One day (default today) or from/to up to 31 days, summed per store only. Read-only.',
        scope: 'reports:read'

      input_schema(
        type: 'object',
        properties: {
          from: DATE_PROPERTY.merge(description: 'First day (inclusive). Default: today.'),
          to: DATE_PROPERTY.merge(description: 'Last day (inclusive). Default: the same day as from.'),
          store: { type: 'string', maxLength: 80, description: 'Only stores whose name contains this text (for example SwipeSimple or a store name).' }
        },
        additionalProperties: false
      )

      def call(args)
        first = date_arg(args, 'from', Date.current)
        last = date_arg(args, 'to', first)
        raise ToolError.new('to must be on or after from.', kind: 'invalid_arguments') if last < first
        raise ToolError.new("Choose a range of #{MAX_DAYS} days or fewer.", kind: 'invalid_arguments') if (last - first).to_i >= MAX_DAYS
        raise ToolError.new('The range cannot end in the future.', kind: 'invalid_arguments') if last > Date.current

        days = (first..last).to_a
        stores = {}
        days.each do |day|
          ::DailyCloseSummary.new(day: day).rows.each do |row|
            next if args['store'].present? && !row.label.to_s.downcase.include?(args['store'].to_s.downcase)

            entry = stores[[row.label, row.currency]] ||= { store: row.label, kind: row.kind, currency: row.currency, days_with_data: 0,
                                                           notes: [], **MEASURES.index_with { 0 } }
            entry[:days_with_data] += 1
            MEASURES.each { |measure| entry[measure] = entry[measure] && row[measure] ? entry[measure] + row[measure] : nil }
            entry[:notes] |= [row.notes] if row.notes.present?
          end
        end
        rows = stores.values.map do |entry|
          missing = days.size - entry[:days_with_data]
          entry[:notes] << "No day stored for #{missing} of #{days.size} days; those days are missing, not zero." if missing.positive?
          entry.except(*MEASURES).merge(MEASURES.to_h { |measure| [:"#{measure == :credit ? 'card' : measure}_cents", entry[measure]] })
        end
        data = { from: first.iso8601, to: last.iso8601, stores: rows,
                 path: Rails.application.routes.url_helpers.daily_reconciliations_path(day: last.iso8601),
                 note: 'Each store separately; never add stores together or to online sales. null = unknown, not zero.' }
        text = if rows.empty?
          "No store register days are stored for #{first} to #{last}. That does not prove there were no sales."
        else
          rows.map { |row| "#{row[:store]}: net #{money(row[:net_cents])} #{row[:currency]}" }.join('; ') + '.'
        end
        result(text, data)
      end
    end
  end
end
