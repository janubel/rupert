# frozen_string_literal: true

# Bounded, tenant-scoped mirror browsing; sources are never added together.
class InventoryWorkspace
  def self.levels(query: nil, source: nil, location_id: nil)
    scope = InventoryLevel.where(source: %w[shopify square]).includes(:location, shopify_variant: :product, square_variation: :item)
    scope = scope.where(source: source) if source.present?
    scope = scope.where(locationId: location_id) if location_id.present?
    if query.present?
      shopify = ShopifyVariant.search(query).select(:id)
      square = SquareVariation.search(query).select(:id)
      scope = scope.where(shopifyVariantId: shopify).or(scope.where(squareVariationId: square))
    end
    scope
  end

  def initialize(levels)
    @levels = levels
    pool_keys = levels.map { |level| [level.source, level.locationId, level.shopifyVariantId || level.squareVariationId] }
    @pools = pool_keys.group_by { |source, location, _item| [source, location] }.reduce(StockReservationPool.none) do |scope, ((source, location), keys)|
      scope.or(StockReservationPool.where(source: source, location_id: location, source_item_id: keys.map(&:last)))
    end.to_a
    @holds = StockReservation.active_at.where(stock_reservation_pool_id: @pools.map(&:id)).group(:stock_reservation_pool_id).sum(:quantity)
    @warehouse = WarehouseStockHold.held.where(variant_id: levels.filter_map(&:shopifyVariantId)).group(:variant_id).sum(:quantity)
    @demand = StockRequest.where(source_pool_id: @pools.map(&:id), request_kind: 'backorder', status: 'pending').group(:source_pool_id).sum(:quantity)
    @incoming = StockRequest.where(destination_pool_id: @pools.map(&:id), request_kind: 'transfer', status: 'dispatched')
      .group(:destination_pool_id).sum('quantity - received_quantity')
    @pools = @pools.index_by { |pool| [pool.source, pool.location_id, pool.source_item_id] }
  end

  def rows
    @levels.map do |level|
      item = level.source == 'shopify' ? level.shopify_variant : level.square_variation
      pool = @pools[[level.source, level.locationId, item&.id]]
      held = @holds.fetch(pool&.id, 0)
      warehouse = level.source == 'shopify' ? @warehouse.fetch(item&.id, 0) : 0
      available = level.local_capacity
      valid_identity = item && item.tenant_id == Current.tenant_id && level.location&.tenant_id == Current.tenant_id &&
        level.location.source == level.source && (level.source == 'shopify' ? level.squareVariationId.nil? : level.shopifyVariantId.nil?)
      { level: level, label: item ? [item.sku.presence, level.source == 'shopify' ? item.title : item.name].compact.join(' · ') : 'Missing catalog identity',
        native_id: item&.id, mirror_quantity: level.sourceQuantity || level.quantity, available: level.available, held: held, warehouse: warehouse,
        promise: valid_identity ? [(available || 0) - held - warehouse, 0].max : 0,
        demand: @demand.fetch(pool&.id, 0), incoming: @incoming.fetch(pool&.id, 0),
        fresh: valid_identity && level.location.active && level.updatedAt.between?(1.hour.ago, Time.current),
        # Presentation only: why promise is what it is (identity, unknown mirror, local capacity).
        valid_identity: valid_identity ? true : false, capacity: available,
        known: !(level.quantity.nil? || level.available.nil? || level.updatedAt.nil? || level.updatedAt > Time.current) }
    end
  end
end
