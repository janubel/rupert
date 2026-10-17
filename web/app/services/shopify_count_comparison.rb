# frozen_string_literal: true

# Physical counts compare native on-hand observations, never available units or
# the historical primary-location aggregate. All reads are from local storage.
class ShopifyCountComparison
  MAX_UNITS = 2_147_483_647

  def initialize(count, skus = nil, at: Time.current)
    @count = count
    @at = at
    return unless Current.tenant_id == count.tenant_id

    @location = Location.find_by(id: count.locationId, tenant_id: count.tenant_id, source: 'shopify')
    @snapshot = ShopifyStockSnapshot.find_by(location_id: @location.id, tenant_id: count.tenant_id) if @location
    @shop_domain = EnvStore.fetch('SHOPIFY_SHOP_DOMAIN', '')
    catalog = ShopifyVariant.where(tenant_id: count.tenant_id)
    skus ||= catalog.where.not(sku: [nil, '']).distinct.pluck(:sku)
    @ids_by_sku = skus.uniq.index_with { |sku| [] }
    catalog.where(sku: skus).pluck(:sku, :id).each { |sku, id| @ids_by_sku[sku] << id }
    SkuLink.where(tenant_id: count.tenant_id, sku: skus).pluck(:sku, :shopifyVariantId).each do |sku, id|
      @ids_by_sku[sku] << id if id.present?
    end
    @ids_by_sku.transform_values!(&:uniq)
    @variants = catalog.includes(:product).where(id: @ids_by_sku.values.flatten).index_by(&:id)
    @records = @snapshot ? @snapshot.records.grep(Hash).group_by { |row| row['id'] } : {}
    @duplicate_skus = count.items.to_a.group_by(&:sku).select { |_, rows| rows.many? }.keys
    @shared_ids = @ids_by_sku.values.select(&:one?).map(&:first).tally.select { |_, n| n > 1 }.keys
  end

  def attributes_for(item)
    metadata = { 'status' => 'unavailable', 'source' => 'shopify', 'location_id' => @location&.id,
                 'location_name' => @location&.name, 'captured_at' => @at.iso8601(6),
                 'quantity_basis' => 'native_on_hand', 'units' => 'whole_units' }
    # Failed rechecks cannot erase the original draft's source binding.
    if item.comparison['source'] == 'shopify'
      metadata.merge!(item.comparison.slice('source_item_id', 'location_id', 'source_location_id', 'shop_domain', 'inventory_item_id'))
    end
    unavailable = ->(reason) { { previousQuantity: nil, comparison_snapshot: metadata.merge('reason' => reason) } }
    return unavailable.call('Choose an active Shopify location in this workspace.') unless @location&.active && @location.externalId.present?
    return unavailable.call('No native Shopify stock snapshot exists for this location.') unless @snapshot
    return unavailable.call('The Shopify shop changed. Refresh native stock before comparing.') unless @shop_domain.present? && @snapshot.shop_domain == @shop_domain
    return unavailable.call('Refresh Shopify stock; this native snapshot is older than one hour or has a future read time.') unless @snapshot.captured_at.between?(@at - 1.hour, @at)
    return unavailable.call('Duplicate SKU rows cannot be compared separately.') if @duplicate_skus.include?(item.sku)

    return unavailable.call('A Shopify count row cannot also identify a Square variation.') if item.squareVariationId.present?

    ids = @ids_by_sku.fetch(item.sku, [])
    return unavailable.call('SKU does not identify one item in this platform.') unless ids.one?
    return unavailable.call('Multiple worksheet SKUs identify the same platform stock pool.') if @shared_ids.include?(ids.first)
    if item.shopifyVariantId.present? && item.shopifyVariantId != ids.first
      return unavailable.call('The scanned item identity changed. Review this row before submitting.')
    end
    prior = item.comparison
    if prior['source'] == 'shopify' && ((prior['shop_domain'].present? && prior['shop_domain'] != @shop_domain) ||
      (prior['location_id'].present? && prior['location_id'] != @location.id) ||
      (prior['source_location_id'].present? && prior['source_location_id'] != @location.externalId) ||
      (prior['source_item_id'].present? && prior['source_item_id'] != ids.first))
      return unavailable.call('The counted Shopify source identity changed. Review this row before submitting.')
    end

    variant = @variants[ids.first]
    return unavailable.call('The linked platform item is no longer in this workspace catalog.') unless variant
    if prior['inventory_item_id'].present? && prior['inventory_item_id'] != variant.inventoryItemId
      return unavailable.call('The native Shopify inventory item identity changed. Review this row before submitting.')
    end
    product = variant.product
    unless variant.catalog_present == true && variant.tracked == true && product&.tenant_id == @count.tenant_id &&
      product.catalog_present == true && product.status == 'ACTIVE'
      return unavailable.call('The Shopify variant must be present, active and stock-tracked in the current catalog.')
    end
    unless variant.catalog_read_at == @snapshot.captured_at && product.catalog_read_at == @snapshot.captured_at
      return unavailable.call('The Shopify catalog and native stock belong to different read epochs. Refresh before comparing.')
    end
    records = @records.fetch(variant.id, [])
    return unavailable.call('No unambiguous native stock row exists for this Shopify location and variant.') unless records.one?

    record = records.first
    unless variant.inventoryItemId.present? && record['inventory_item_id'] == variant.inventoryItemId
      return unavailable.call('The native Shopify inventory item identity changed or is missing.')
    end
    quantity = record['on_hand']
    unless quantity.is_a?(Integer) && quantity.between?(-MAX_UNITS - 1, MAX_UNITS)
      return unavailable.call('Native Shopify on-hand stock is missing, fractional or outside the whole-unit worksheet range.')
    end

    metadata.merge!('status' => 'matched', 'source_item_id' => variant.id, 'inventory_item_id' => variant.inventoryItemId,
      'source_location_id' => @location.externalId, 'shop_domain' => @snapshot.shop_domain,
      'stock_snapshot_id' => @snapshot.id, 'mirrored_at' => @snapshot.captured_at.iso8601(6))
    { shopifyVariantId: variant.id, previousQuantity: quantity, comparison_snapshot: metadata }
  end

  def prepared_items
    return [] unless @ids_by_sku

    @ids_by_sku.keys.sort.filter_map do |sku|
      item = InventoryCountItem.new(sku: sku)
      attributes = attributes_for(item)
      next unless attributes[:comparison_snapshot]['status'] == 'matched'

      item.assign_attributes(attributes.merge(quantity: [attributes[:previousQuantity], 0].max))
      item
    end
  end
end
