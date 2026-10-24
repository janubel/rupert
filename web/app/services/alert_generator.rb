# frozen_string_literal: true

# Port of seedAlerts from the legacy script — opens low/out-of-stock alerts
# for tracked variants, without duplicating open alerts per variant.
class AlertGenerator
  # Backwards-compatible default when no tenant context / settings are set.
  THRESHOLD = 5

  class << self
    def sync!
      threshold = threshold_for_current_tenant
      # Load every open alert once so the per-variant pass is in-memory, not one
      # find_by per variant (which previously ran twice per full sync).
      open_alerts = StockAlert.where(status: 'open')
                              .where(shopifyVariantId: ShopifyVariant.select(:id))
                              .group_by(&:shopifyVariantId)
      created = 0
      resolved = 0
      # Only sellable (ACTIVE) products generate alerts. Archived/DRAFT/UNLISTED
      # products were dropped from the live catalog — they must not reopen alerts.
      ShopifyVariant.joins(:product).merge(ShopifyProduct.active)
                    .where.not(sku: [nil, '']).find_each do |variant|
        variant_id = variant.id
        quantity = variant.inventoryQuantity.to_i
        if quantity > threshold
          next if open_alerts[variant_id].blank?

          StockAlert.where(id: open_alerts[variant_id].map(&:id)).update_all(
            status: 'resolved',
            resolvedAt: Time.current,
            quantity: quantity,
            note: "Stock recovered to #{quantity} (above threshold of #{threshold})"
          )
          resolved += 1
        elsif open_alerts[variant_id].blank?
          StockAlert.create!(
            shopifyVariantId: variant_id,
            sku: variant.sku,
            quantity: quantity,
            threshold: threshold,
            status: 'open',
            note: quantity <= 0 ? 'Out of stock' : "Low stock — below threshold of #{threshold}",
            createdAt: Time.current
          )
          created += 1
        end
      end
      { created: created, resolved: resolved + retire_unsold! }
    end

    # Alerts for products no longer sold on Shopify (archived, draft, removed from the catalog, or the SKU taken
    # off) were never revisited above, so they stayed open for good (503 of 627 open on 2026-10-23). Close them
    # with the reason; if the product is sold again and still low, the pass above opens a fresh alert.
    def retire_unsold!
      sellable = ShopifyVariant.joins(:product).merge(ShopifyProduct.active).where.not(sku: [nil, '']).select(:id)
      StockAlert.open.where.not(shopifyVariantId: nil).where.not(shopifyVariantId: sellable).update_all(
        status: 'resolved', resolvedAt: Time.current,
        note: 'Closed: no longer sold on Shopify (archived, draft or removed from the catalog)'
      )
    end

    def sync_variant!(variant_id, sku, quantity)
      threshold = threshold_for_current_tenant
      return resolve_recovered!(variant_id, quantity, threshold) if quantity > threshold

      existing = StockAlert.find_by(shopifyVariantId: variant_id, status: 'open')
      return if existing

      StockAlert.create!(
        shopifyVariantId: variant_id,
        sku: sku,
        quantity: quantity,
        threshold: threshold,
        status: 'open',
        note: quantity <= 0 ? 'Out of stock' : "Low stock — below threshold of #{threshold}",
        createdAt: Time.current
      )
    end

    # Close the alert loop: when stock recovers above the threshold, mark any
    # open alerts for that variant resolved instead of leaving them open until
    # a human resolves them manually.
    def resolve_recovered!(variant_id, quantity, threshold)
      open_alerts = StockAlert.where(shopifyVariantId: variant_id, status: 'open')
      return if open_alerts.none?

      open_alerts.update_all(
        status: 'resolved',
        resolvedAt: Time.current,
        quantity: quantity,
        note: "Stock recovered to #{quantity} (above threshold of #{threshold})"
      )
    end

    def threshold_for_current_tenant
      return THRESHOLD if Current.tenant_id.blank?

      TenantSettings.low_stock_threshold_int
    end
  end
end
