# frozen_string_literal: true

module Mcp
  module Tools
    class InventorySearch < Tool
      tool 'inventory_search',
        title: 'Search inventory',
        description: 'Searches Rupert\'s mirrored Shopify and Square stock by SKU or item name and returns one row per item ' \
                     'and location: quantity, available, and when it was last updated. Each platform/location is an ' \
                     'independent observation — never add Shopify and Square quantities together. A null quantity is ' \
                     'unknown, not zero. Paginated (max 50 rows per page). Read-only; nothing is written to any platform.',
        scope: 'inventory:read'

      input_schema(
        type: 'object',
        properties: {
          query: { type: 'string', maxLength: 100, description: 'SKU (exact or partial) or item name fragment. Blank lists everything.' },
          source: { type: 'string', enum: %w[shopify square], description: 'Only this platform.' },
          location_id: { type: 'string', maxLength: 100, description: 'Only this Rupert location ID (see rows[].location_id).' },
          low_stock_first: { type: 'boolean', description: 'Sort by lowest available first. Default false.' },
          **PAGE_PROPERTIES
        },
        additionalProperties: false
      )

      def call(args)
        scope = InventoryWorkspace.levels(query: args['query'].to_s.strip, source: args['source'], location_id: args['location_id'])
        scope = args['low_stock_first'] ? scope.order(:available, :id) : scope.order(:source, :locationId, :id)
        levels, meta = paginate(scope, args)
        rows = levels.map do |level|
          item = level.source == 'shopify' ? level.shopify_variant : level.square_variation
          { source: level.source, location_id: level.locationId, location: level.location&.name,
            item_id: item&.id, sku: item&.sku, name: item_name(level, item),
            quantity: level.quantity, available: level.available, updated_at: iso(level.updatedAt) }
        end
        text = if rows.empty?
          "No stock rows match#{" \"#{args['query']}\"" if args['query'].present?}."
        else
          "#{rows.size} stock row#{'s' unless rows.size == 1} (page #{meta[:page]}#{', more available' if meta[:has_more]}): " +
            rows.first(10).map { |r| "#{r[:sku] || r[:name]} @ #{r[:location] || r[:location_id]} (#{r[:source]}) available #{r[:available].nil? ? 'unknown' : r[:available]}" }.join('; ') +
            (rows.size > 10 ? '; …' : '.')
        end
        result(text, { rows: rows, meta: meta })
      end

      private

      def item_name(level, item)
        return nil unless item

        level.source == 'shopify' ? [item.product&.title, item.title].compact.join(' · ') : [item.item&.name, item.name].compact.join(' · ')
      end
    end
  end
end
