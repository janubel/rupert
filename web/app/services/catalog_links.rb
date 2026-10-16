# frozen_string_literal: true

# Catalog identity audit: which sellable items are correctly identified across
# Shopify and Square. Shopify and Square are separate locations serving the
# same items from independent inventories, so quantities are NEVER compared
# here — a link means "same sellable item", nothing more. Stock differences
# between locations are normal operation, not drift.
#
# Statuses:
#   matched    — linked pair whose SKUs agree (the healthy case)
#   mismatched — linked pair whose SKUs differ (needs a decision: re-SKU or unlink;
#                SKU writes always need explicit owner sign-off)
class CatalogLinks
  Row = Struct.new(
    :sku,
    :shopify_title,
    :product_title,
    :shopify_qty,
    :square_name,
    :square_sku,
    :square_qty,
    :status,
    keyword_init: true
  )

  class << self
    # Linked pairs, worst first (mismatches at top), then by product title.
    def rows
      square_totals = InventoryLevel.square_totals

      SkuLink.linked.includes(:square_variation, shopify_variant: [:product]).filter_map do |link|
        variant = link.shopify_variant
        variation = link.square_variation
        next if variant.nil? || variation.nil?

        square_sku = variation.sku.presence
        status = link.sku.to_s.downcase == square_sku.to_s.downcase ? 'matched' : 'mismatched'

        Row.new(
          sku: link.sku,
          shopify_title: variant.title,
          product_title: variant.product&.title,
          shopify_qty: variant.inventoryQuantity.to_i,
          square_name: variation.name,
          square_sku: square_sku,
          square_qty: square_totals[variation.id] || 0,
          status: status
        )
      end.sort_by { |row| [row.status == 'matched' ? 1 : 0, row.product_title.to_s.downcase] }
    end

    def summary
      rows = self.rows
      linked = rows.length
      matched = rows.count { |r| r.status == 'matched' }

      # Anti-joins via subquery over COMPLETE links only (both sides present):
      # a dead half-link row means the item is effectively one-sided.
      # where.missing/left_joins break under TenantScoped's default_scope (the
      # scope lands in WHERE and kills the NULL rows a LEFT JOIN needs).
      linked_shopify_ids = SkuLink.linked.select(:shopifyVariantId)
      linked_square_ids = SkuLink.linked.select(:squareVariationId)

      {
        linked: linked,
        matched: matched,
        mismatched: linked - matched,
        shopify_only: ShopifyVariant.joins(:product)
                                    .merge(ShopifyProduct.active)
                                    .where.not(sku: [nil, ''])
                                    .where.not(id: linked_shopify_ids).count,
        square_only: SquareVariation.where.not(sku: [nil, ''])
                                    .where.not(id: linked_square_ids).count
      }
    end
  end
end
