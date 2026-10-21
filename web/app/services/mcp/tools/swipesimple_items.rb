# frozen_string_literal: true

module Mcp
  module Tools
    class SwipesimpleItems < Tool
      tool 'swipesimple_items',
        title: 'SwipeSimple items matched to Shopify, Square and C-Trax',
        description: 'Lists the latest imported SwipeSimple item list with each item lined up against the same item in ' \
                     'Shopify (by exact SKU/barcode/ID, or a product-words match flagged for review), plus the Square and ' \
                     'C-Trax names and a suggested SwipeSimple name when names differ. Same data as the in-app SwipeSimple ' \
                     'items page. Stock figures are each system\'s own count; null stock is unknown. Paginated. Read-only; ' \
                     'nothing is written to SwipeSimple or any other system.',
        scope: 'inventory:read'

      input_schema(
        type: 'object',
        properties: {
          merchant_account: { type: 'string', maxLength: 120, description: 'SwipeSimple merchant account. Default: the most recently imported.' },
          status: { type: 'string', enum: SwipesimpleItemMatch::STATUSES, description: 'Only rows with this match status.' },
          query: { type: 'string', maxLength: 100, description: 'Text in the SwipeSimple name, SKU or barcode.' },
          **PAGE_PROPERTIES
        },
        additionalProperties: false
      )

      def call(args)
        snapshots = SwipesimpleItemSnapshot.order(:merchant_account).to_a
        snapshot = if args['merchant_account'].present?
          snapshots.find { |s| s.merchant_account.casecmp?(args['merchant_account'].strip) } ||
            raise(ToolError.new("No SwipeSimple item list is imported for #{args['merchant_account'].first(60)}. " \
                                "Imported accounts: #{snapshots.map(&:merchant_account).join(', ').presence || 'none'}.", kind: 'not_found'))
        else
          snapshots.max_by(&:captured_at)
        end
        return result('No SwipeSimple item list has been imported yet (Inventory → SwipeSimple items).', { rows: [], summary: nil }) unless snapshot

        match = SwipesimpleItemMatch.new(snapshot)
        rows = match.rows
        rows = rows.select { |row| row.status == args['status'] } if args['status']
        rows = rows.select { |row| matches_query?(row, args['query']) } if args['query'].present?
        page, meta = paginate(rows, args)
        data = {
          merchant_account: snapshot.merchant_account, imported_at: iso(snapshot.captured_at), accounts: snapshots.map(&:merchant_account),
          summary: match.summary, rows: page.map { |row| row_data(row) }, meta: meta
        }
        summary = match.summary
        text = "#{snapshot.merchant_account}: #{summary[:items]} SwipeSimple items — #{summary[:matched]} matched, #{summary[:review]} to " \
               "review, #{summary[:unmatched]} not matched, #{summary[:names_differ]} with a different name. Showing #{page.size} of " \
               "#{meta[:total]}#{', more available' if meta[:has_more]}."
        result(text, data)
      end

      private

      def matches_query?(row, query)
        needle = query.strip.downcase
        [row.swipesimple_name, row.record['sku'], row.record['barcode']].compact.any? { |value| value.to_s.downcase.include?(needle) }
      end

      def row_data(row)
        record = row.record
        { name: row.swipesimple_name, sku: record['sku'], barcode: record['barcode'], category: record['category'],
          price: record['price'], swipesimple_quantity: record['quantity'], status: row.status, identity: row.identity,
          shopify_name: row.shopify_name, shopify_sku: row.shopify_sku, square_name: row.square_name, ctrax_name: row.ctrax_name,
          name_status: row.name_status, suggested_name: row.suggested_name, notes: (Array(row.evidence) + Array(row.issues)).first(5) }
      end
    end
  end
end
