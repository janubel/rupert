# frozen_string_literal: true

class InventoryLevel < ApplicationRecord
  include HasCuid
  include TenantScoped

  self.table_name = 'InventoryLevel'
  self.primary_key = 'id'

  belongs_to :location,
    class_name: 'Location',
    foreign_key: 'locationId',
    optional: true
  belongs_to :shopify_variant,
    class_name: 'ShopifyVariant',
    foreign_key: 'shopifyVariantId',
    optional: true
  belongs_to :square_variation,
    class_name: 'SquareVariation',
    foreign_key: 'squareVariationId',
    optional: true

  # Platform-reported stock below zero (oversold). `quantity` stays clamped to
  # zero for the rest of the app; `sourceQuantity` keeps the raw figure.
  scope :oversold, -> { where('"sourceQuantity" < 0') }

  def oversold?
    sourceQuantity.to_i.negative?
  end

  def self.total_for_variant(variant_id)
    where(shopifyVariantId: variant_id).sum(:quantity)
  end

  # Future read times cannot establish that this stock has been observed yet.
  def local_capacity(at: Time.current)
    return 0 if updatedAt.nil? || updatedAt > at || quantity.nil? || available.nil?

    [quantity, available].min.clamp(0, Float::INFINITY)
  end

  def self.warehouse_quantities(tenant_id:, variant_ids:)
    return {} if tenant_id.blank? || variant_ids.empty?

    quantities = unscoped.where(tenant_id: tenant_id, source: 'shopify', shopifyVariantId: variant_ids, squareVariationId: nil)
      .where('"InventoryLevel"."updatedAt" <= ?', Time.current)
      .group(:shopifyVariantId).sum('CASE WHEN quantity IS NULL OR available IS NULL THEN 0 WHEN quantity < available THEN CASE WHEN quantity > 0 THEN quantity ELSE 0 END ELSE CASE WHEN available > 0 THEN available ELSE 0 END END')
    local = StockReservation.unscoped.active_at.joins(:stock_reservation_pool)
      .where(tenant_id: tenant_id, stock_reservation_pools: { tenant_id: tenant_id, source: 'shopify', source_item_id: variant_ids })
      .group('stock_reservation_pools.source_item_id').sum(:quantity)
    holds = WarehouseStockHold.unscoped.held.where(tenant_id: tenant_id, variant_id: variant_ids).group(:variant_id).sum(:quantity)
    variant_ids.to_h { |id| [id, [quantities.fetch(id, 0) - holds.fetch(id, 0) - local.fetch(id, 0), 0].max] }
  end

  def self.total_for_variation(variation_id)
    where(squareVariationId: variation_id).sum(:quantity)
  end

  # Mirrors for a single source: legacy quantities plus per-item
  # totals. Shopify normally stores available units or an aggregate fallback.
  # Used all over the sync engine and reports — centralizing here keeps
  # the query convention in one place.
  scope :mirrored, ->(source) { where(source: source) }

  # { source_item_id => total quantity } for a source, narrowed to one column.
  def self.totals_by(source, item_column)
    mirrored(source).group(item_column).sum(:quantity)
  end

  def self.square_totals
    totals_by('square', :squareVariationId)
  end

  def self.shopify_totals
    totals_by('shopify', :shopifyVariantId)
  end
end
