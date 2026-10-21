# frozen_string_literal: true

module Mcp
  module Tools
    class StockComparison < Tool
      FILTERS = %w[all attention unmatched candidates historical findings].freeze

      tool 'stock_comparison',
        title: 'Shopify vs C-Trax stock comparison',
        description: 'Compares the latest Shopify stock read with the latest C-Trax (retail physical count) read, item by ' \
                     'item, for one pair of locations. Two observations side by side — never a sum or an adjustment. ' \
                     'difference is C-Trax minus Shopify on hand, and is null when the pair is not safely comparable ' \
                     '(stale read, unknown stock, name-only match). Use filter=attention to see problems. Paginated. Read-only.',
        scope: 'inventory:read'

      input_schema(
        type: 'object',
        properties: {
          query: { type: 'string', maxLength: 100, description: 'Item name, SKU, barcode or ID fragment.' },
          filter: { type: 'string', enum: FILTERS, description: 'attention = issues or a nonzero difference; unmatched = no pair. Default all.' },
          shopify_location_id: { type: 'string', maxLength: 100, description: 'Rupert location ID of the Shopify side. Default: first with stock.' },
          ctrax_location_id: { type: 'string', maxLength: 100, description: 'Rupert location ID of the C-Trax store. Default: first.' },
          **PAGE_PROPERTIES
        },
        additionalProperties: false
      )

      def call(args)
        comparison = ::StockComparison.new(shopify_location_id: args['shopify_location_id'], ctrax_location_id: args['ctrax_location_id'],
          query: args['query'], filter: args['filter'])
        if comparison.shopify.nil? && comparison.ctrax.nil?
          return result('No Shopify or C-Trax stock reads are stored yet, so there is nothing to compare.', { rows: [], summary: {} })
        end

        rows, meta = paginate(comparison.rows, args)
        data = {
          shopify: snapshot(comparison.shopify, comparison), ctrax: snapshot(comparison.ctrax, comparison),
          summary: comparison.summary, filter: comparison.filter,
          rows: rows.map do |row|
            row.slice(:label, :sku, :shopify_id, :ctrax_id, :identity, :paired, :on_hand, :available, :committed, :issues)
              .merge(ctrax_quantity: row[:ctrax_quantity]&.to_s('F'), difference: row[:difference]&.to_s('F'))
          end,
          meta: meta
        }
        summary = comparison.summary
        text = "#{summary[:rows]} items compared (#{summary[:paired]} paired, #{summary[:unpaired]} unpaired, #{summary[:unknown]} unknown stock, " \
               "#{summary[:negative]} negative). Showing #{rows.size} (#{comparison.filter}), page #{meta[:page]}#{', more available' if meta[:has_more]}."
        result(text, data)
      end

      private

      def snapshot(snapshot, comparison)
        return nil unless snapshot

        { location_id: snapshot.location_id, location: snapshot.location&.name, captured_at: iso(snapshot.captured_at), stale: !!comparison.stale?(snapshot) }
      end
    end
  end
end
