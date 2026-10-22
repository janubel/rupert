# frozen_string_literal: true

module Mcp
  module Tools
    # Links canonical sales/inventory rows to Rupert's own stock observations.
    # Each platform/location remains separate; quantities are never summed.
    module StockEnrichment
      module_function

      def for_skus(skus, include_alerts: true)
        skus = Array(skus).compact_blank.map(&:to_s).uniq
        return {} if skus.empty?

        shopify = ShopifyVariant.where(sku: skus).to_a
        square = SquareVariation.where(sku: skus).to_a
        levels = levels_for(shopify, square)
        alerts = (include_alerts ? alerts_for(shopify, square) : []).index_by do |alert|
          alert.shopifyVariantId.present? ? ['shopify', alert.shopifyVariantId] : ['square', alert.squareVariationId]
        end
        threshold = TenantSettings.low_stock_threshold_int

        levels.each_with_object(Hash.new { |hash, key| hash[key] = { observations: [] } }) do |level, result|
          item = level.source == 'shopify' ? level.shopify_variant : level.square_variation
          next unless item&.sku.present?

          alert = alerts[[level.source, item.id]]
          result[item.sku][:observations] << {
            source: level.source, item_id: item.id, name: item_name(level, item), location_id: level.locationId, location: level.location&.name,
            on_hand: level.quantity, available: level.available, low: (level.quantity.nil? ? nil : level.quantity <= threshold),
            alert_id: (alert&.id if include_alerts), alerts_available: include_alerts
          }
        end.transform_values do |stock|
          lows = stock[:observations].filter_map { |row| row[:low] }
          stock.merge(available: true, alerts_available: include_alerts,
            low: lows.include?(true) ? true : (lows.any? ? false : nil))
        end
      end

      def levels_for(shopify, square)
        shopify_ids = shopify.map(&:id)
        square_ids = square.map(&:id)
        return [] if shopify_ids.empty? && square_ids.empty?

        scopes = []
        scopes << InventoryLevel.where(shopifyVariantId: shopify_ids) if shopify_ids.any?
        scopes << InventoryLevel.where(squareVariationId: square_ids) if square_ids.any?
        scope = scopes.reduce(&:or)
        scope.includes(:location, shopify_variant: :product, square_variation: :item).to_a
      end

      def alerts_for(shopify, square)
        shopify_ids = shopify.map(&:id)
        square_ids = square.map(&:id)
        scopes = []
        scopes << StockAlert.open.where(shopifyVariantId: shopify_ids) if shopify_ids.any?
        scopes << StockAlert.open.where(squareVariationId: square_ids) if square_ids.any?
        scope = scopes.reduce(&:or)
        scope.to_a
      end

      def item_name(level, item)
        level.source == 'shopify' ? [item.product&.title, item.title].compact.join(' · ') : [item.item&.name, item.name].compact.join(' · ')
      end
    end
  end
end
