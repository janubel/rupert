# frozen_string_literal: true

module Mcp
  module Tools
    class ListAlerts < Tool
      STATUSES = %w[open resolved ignored all].freeze

      tool 'list_alerts',
        title: 'List low-stock alerts',
        description: 'Lists Rupert low-stock alerts (the in-app Alerts page): SKU, item, platform quantity, threshold and ' \
                     'status. Default status open, lowest quantity first. Counts per status are included. Paginated. Read-only.',
        scope: 'alerts:read'

      input_schema(
        type: 'object',
        properties: {
          status: { type: 'string', enum: STATUSES, description: 'Default open.' },
          query: { type: 'string', maxLength: 100, description: 'SKU fragment.' },
          **PAGE_PROPERTIES
        },
        additionalProperties: false
      )

      def call(args)
        status = args['status'] || 'open'
        scope = StockAlert.by_status(status).includes(shopify_variant: :product, square_variation: :item)
        scope = scope.where('sku LIKE ?', "%#{StockAlert.sanitize_sql_like(args['query'].strip)}%") if args['query'].present?
        scope = status == 'open' ? scope.order(:quantity, :id) : scope.order(createdAt: :desc, id: :desc)
        alerts, meta = paginate(scope, args)
        counts = StockAlert.group(:status).count
        rows = alerts.map do |alert|
          { id: alert.id, sku: alert.sku, product: alert.product_name, variant: alert.variant_name,
            platform: alert.shopifyVariantId ? 'shopify' : (alert.squareVariationId ? 'square' : nil),
            quantity: alert.quantity, threshold: alert.threshold, status: alert.status, note: alert.note,
            created_at: iso(alert.createdAt), resolved_at: iso(alert.resolvedAt) }
        end
        text = "#{counts.fetch('open', 0)} open alerts. Showing #{rows.size} #{status}#{' (more available)' if meta[:has_more]}" +
               (rows.any? ? ': ' + rows.first(10).map { |r| "#{r[:sku] || r[:product]} qty #{r[:quantity]} (threshold #{r[:threshold]})" }.join('; ') : '.')
        result(text, { counts: counts, rows: rows, meta: meta })
      end
    end
  end
end
