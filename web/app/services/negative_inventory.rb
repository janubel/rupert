# frozen_string_literal: true

# Detects negative inventory levels (oversold or non-inventory SKUs being
# tracked) and corrects them: Square counts are zeroed with a physical count,
# Shopify mirror rows are zeroed and their variants untracked so they stop
# being reconciled. Mirrored levels are journaled as movements.
class NegativeInventory
  Item = Struct.new(:id, :sku, :name, :location, :quantity, keyword_init: true)

  class << self
    def summary(limit: 50)
      square = negative_levels('square')
      shopify = negative_levels('shopify')
      {
        total: square.length + shopify.length,
        square: square.first(limit),
        shopify: shopify.first(limit)
      }
    end

    def fix!(source:, id:)
      source == 'square' ? fix_square_variation!(id) : fix_shopify_variant!(id)
    end

    def fix_all!
      square_variation_ids = InventoryLevel.where(source: 'square').where('quantity < 0').distinct.pluck(:squareVariationId)
      shopify_variant_ids = InventoryLevel.where(source: 'shopify').where('quantity < 0').distinct.pluck(:shopifyVariantId)

      results = { square: 0, shopify: 0, failed: 0 }
      square_variation_ids.each { |id| fix_square_variation!(id) ? results[:square] += 1 : results[:failed] += 1 }
      shopify_variant_ids.each { |id| fix_shopify_variant!(id) ? results[:shopify] += 1 : results[:failed] += 1 }
      results
    end

    private

    # Reads the platform's own figure: Shopify levels are stored clamped at 0 with the real (oversold) figure in
    # sourceQuantity. The fixes above keep selecting on the stored quantity, so this does not widen any write.
    def negative_levels(source)
      raw = Arel.sql('COALESCE("sourceQuantity", quantity)')
      InventoryLevel.where(source: source)
                    .where(Arel.sql('COALESCE("sourceQuantity", quantity) < 0'))
                    .order(raw)
                    .includes(:square_variation, :shopify_variant, :location)
                    .map do |level|
        if source == 'square'
          variation = level.square_variation
          sku = variation&.sku
          name = variation&.name
        else
          variant = level.shopify_variant
          sku = variant&.sku
          name = variant&.title
        end
        Item.new(
          id: source == 'square' ? level.squareVariationId : level.shopifyVariantId,
          sku: sku,
          name: name,
          location: level.location&.name,
          quantity: level.sourceQuantity || level.quantity
        )
      end
    end

    def fix_square_variation!(variation_id)
      return false if variation_id.blank?

      levels = InventoryLevel.where(source: 'square', squareVariationId: variation_id).where('quantity < 0')
      return false if levels.empty?

      # Multi-approval gate before any outbound write to Square.
      PlatformPushGuard.authorize!('square', actor: 'user')

      sku = SquareVariation.find_by(id: variation_id)&.sku
      before = InventoryLevel.total_for_variation(variation_id)

      levels.each do |level|
        location = level.location
        next if location.nil?

        InventoryWriter.physical_count!(
          catalog_object_id: variation_id,
          quantity: 0,
          location: location,
          reference_id: "hh-neg-#{variation_id}",
          idempotency_key: "hh-neg-#{variation_id}-#{level.id}-#{level.quantity}"
        )
        level.update!(quantity: 0, available: 0, updatedAt: Time.current)
      end

      InventoryMovement.create!(
        sku: sku,
        squareVariationId: variation_id,
        source: 'negative-fix',
        direction: (-before).negative? ? 'out' : 'in',
        delta: -before,
        quantityBefore: before,
        quantityAfter: 0,
        reason: 'Corrected negative Square inventory',
        reference: 'inventory-banner',
        actor: 'user',
        createdAt: Time.current
      )
      true
    rescue StandardError => e
      Rails.logger.error("NegativeInventory square fix failed for #{variation_id}: #{e.class}: #{e.message}")
      false
    end

    def fix_shopify_variant!(variant_id)
      return false if variant_id.blank?

      levels = InventoryLevel.where(source: 'shopify', shopifyVariantId: variant_id).where('quantity < 0')
      return false if levels.empty?

      before = InventoryLevel.total_for_variant(variant_id)
      variant = ShopifyVariant.find_by(id: variant_id)
      variant&.update!(tracked: false)
      levels.update_all(quantity: 0, available: 0, updatedAt: Time.current)

      InventoryMovement.create!(
        sku: variant&.sku,
        shopifyVariantId: variant_id,
        source: 'negative-fix',
        direction: (-before).negative? ? 'out' : 'in',
        delta: -before,
        quantityBefore: before,
        quantityAfter: 0,
        reason: 'Zeroed negative Shopify mirror (non-inventory SKU)',
        reference: 'inventory-banner',
        actor: 'user',
        createdAt: Time.current
      )
      true
    rescue StandardError => e
      Rails.logger.error("NegativeInventory shopify fix failed for #{variant_id}: #{e.class}: #{e.message}")
      false
    end
  end
end
