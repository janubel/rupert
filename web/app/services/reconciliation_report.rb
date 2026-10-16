# frozen_string_literal: true

require 'csv'

# Side-by-side Shopify vs Square inventory snapshot for the Reconciliation
# report. Data comes from the sync mirrors (updated every 15 minutes), so this
# is a live compare: every linked SKU's Shopify count next to Square's count,
# plus the unmatched items on each side.
class ReconciliationReport
  Row = Struct.new(
    :sku, :product, :shopify_variant, :square_variation,
    :shopify_qty, :square_qty, :delta, :status, :shared,
    keyword_init: true
  )

  def initialize
    @square_totals = InventoryLevel.square_totals
    # Square variations linked to more than one Shopify variant can't be pinned
    # to a single row — flag them (†) instead of reading the shared total as one
    # variant's number (same guard as the PDF report and Inventory page).
    @shared_sq_variations = SkuLink.linked.group(:squareVariationId).count
                                   .select { |_, n| n > 1 }.keys.to_set
  end

  def matched_rows
    @matched_rows ||= SkuLink.linked
                             .joins(shopify_variant: :product)
                             .merge(ShopifyProduct.active)
                             .includes(shopify_variant: :product, square_variation: :item)
                             .order(:sku)
                             .filter_map do |link|
                               variant = link.shopify_variant
                               variation = link.square_variation
                               next unless variant && variation

                               shopify_qty = variant.inventoryQuantity.to_i
                               square_qty = square_qty(link.squareVariationId)
                               delta = square_qty - shopify_qty
                               shared = @shared_sq_variations.include?(link.squareVariationId)
                               Row.new(
                                 sku: link.sku,
                                 product: variant.product&.title || variation.item&.name,
                                 shopify_variant: variant.title,
                                 square_variation: variation.name,
                                 shopify_qty: shopify_qty,
                                 square_qty: square_qty,
                                 delta: delta,
                                 status: if delta.zero? && !shared
                                           'matched'
                                         else
                                           (shared ? 'shared' : 'drift')
                                         end,
                                 shared: shared
                               )
                             end
  end

  def square_only_rows
    @square_only_rows ||= begin
      linked = SkuLink.where.not(squareVariationId: nil).pluck(:squareVariationId)
      SquareVariation.where.not(id: linked).includes(:item).order(:sku).filter_map do |variation|
        next if variation.sku.blank?

        Row.new(
          sku: variation.sku,
          product: variation.item&.name,
          square_variation: variation.name,
          square_qty: square_qty(variation.id),
          status: 'square_only'
        )
      end
    end
  end

  def shopify_only_rows
    @shopify_only_rows ||= begin
      linked = SkuLink.where.not(shopifyVariantId: nil).pluck(:shopifyVariantId)
      ShopifyVariant.joins(:product).merge(ShopifyProduct.active)
                    .where.not(id: linked).includes(:product).order(:sku).filter_map do |variant|
        next if variant.sku.blank?

        Row.new(
          sku: variant.sku,
          product: variant.product&.title,
          shopify_variant: variant.title,
          shopify_qty: variant.inventoryQuantity.to_i,
          status: 'shopify_only'
        )
      end
    end
  end

  def rows
    matched_rows + square_only_rows + shopify_only_rows
  end

  def summary
    matched = matched_rows
    drift = matched.count { |row| row.status == 'drift' }
    {
      linked: matched.length,
      drift: drift,
      in_sync: matched.length - drift,
      square_only: square_only_rows.length,
      shopify_only: shopify_only_rows.length
    }
  end

  def last_syncs
    shopify = Location.shopify_primary
    square = Location.square_primary
    {
      shopify: shopify&.syncedAt,
      square: square&.syncedAt
    }
  end

  # The maintainer's automated decisions for the audit trail: every journaled
  # write (which SKU, which platform, before -> after, delta). Anything with a
  # large move or a negative result is flagged for human review.
  def decisions(since: 24.hours.ago)
    @decisions ||= InventoryMovement.where(source: 'maintain')
                                    .where('"createdAt" >= ?', since)
                                    .order(:createdAt)
                                    .map do |movement|
                                      {
                                        time: movement.createdAt,
                                        sku: movement.sku,
                                        platform: movement.shopifyVariantId.present? ? 'shopify' : 'square',
                                        delta: movement.delta,
                                        before: movement.quantityBefore,
                                        after: movement.quantityAfter,
                                        reason: movement.reason,
                                        needs_review: (movement.delta.to_i.abs > 10) || movement.quantityAfter.to_i.negative?
                                      }
                                    end
  end

  def csv
    CSV.generate do |csv|
      csv << ['SKU', 'Product', 'Shopify variant', 'Square variation', 'Shopify qty', 'Square qty', 'Delta', 'Status']
      rows.each do |row|
        csv << [
          row.sku,
          row.product,
          row.shopify_variant,
          row.square_variation,
          row.shopify_qty,
          row.square_qty,
          row.delta,
          row.status
        ]
      end
    end
  end

  private

  def square_qty(variation_id)
    @square_totals.fetch(variation_id, 0).to_i
  end
end
