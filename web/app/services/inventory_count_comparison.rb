# frozen_string_literal: true

# Compare a worksheet with one stored platform/location/item pool. A missing
# mirror is unknown, never zero. This does not fetch or write platform data.
class InventoryCountComparison
  def self.snapshot(count:, item:)
    new(count, [item.sku]).attributes_for(item)
  end

  def self.capture_all!(count)
    items = count.items.to_a
    comparison = new(count, items.map(&:sku))
    items.each { |item| item.update!(comparison.attributes_for(item)) }
  end

  def self.prepared_items(count)
    comparison = new(count)
    comparison.prepared_items
  end

  def initialize(count, skus = nil)
    @count = count
    @location = Location.find_by(id: count.locationId, tenant_id: count.tenant_id)
    if @location&.source == 'ctrax'
      @native = Ctrax::CountComparison.new(count)
      return
    end
    if @location&.source == 'shopify'
      @native = ShopifyCountComparison.new(count, skus)
      return
    end
    return unless @location&.source == 'square'

    @key = :squareVariationId
    @opposite = :shopifyVariantId
    catalog = SquareVariation.where(tenant_id: count.tenant_id)
    levels = InventoryLevel.where(tenant_id: count.tenant_id, source: @location.source, locationId: @location.id)
    skus ||= catalog.where(id: levels.select(@key)).where.not(sku: [nil, '']).distinct.pluck(:sku)
    skus = skus.uniq
    direct = catalog.where(sku: skus).pluck(:sku, :id).group_by(&:first)
    links = SkuLink.where(tenant_id: count.tenant_id, sku: skus).pluck(:sku, @key).group_by(&:first)
    @ids_by_sku = skus.index_with do |sku|
      ((direct[sku] || []) + (links[sku] || [])).map(&:last).compact_blank.uniq
    end
    @shared_ids = @ids_by_sku.values.select(&:one?).map(&:first).tally.select { |_, n| n > 1 }.keys
    ids = @ids_by_sku.values.flatten.uniq
    @source_items = catalog.includes(:item).where(id: ids).index_by(&:id)
    @levels_by_item = levels.where(@key => ids).to_a.group_by { |level| level[@key] }
    @duplicates = count.new_record? ? [] : count.items.group(:sku).count.select { |_, n| n > 1 }.keys
  end

  def attributes_for(item)
    return @native.attributes_for(item) if @native

    metadata = {
      'status' => 'unavailable', 'captured_at' => Time.current.iso8601(6),
      'location_id' => @count.locationId, 'location_name' => @location&.name,
      'source' => @location&.source
    }
    unavailable = ->(reason) { { previousQuantity: nil, comparison_snapshot: metadata.merge('reason' => reason) } }
    return unavailable.call('Choose a platform location to compare stock.') unless @location
    return unavailable.call('This location has no supported platform stock mirror.') unless @ids_by_sku
    return unavailable.call('Duplicate SKU rows cannot be compared separately.') if @duplicates.include?(item.sku)

    ids = @ids_by_sku.fetch(item.sku, [])
    return unavailable.call('SKU does not identify one item in this platform.') unless ids.one?
    if @shared_ids.include?(ids.first)
      return unavailable.call('Multiple worksheet SKUs identify the same platform stock pool.')
    end
    if item[@key].present? && item[@key] != ids.first
      return unavailable.call('The scanned item identity changed. Review this row before submitting.')
    end

    source_item = @source_items[ids.first]
    return unavailable.call('The linked platform item is no longer in this workspace catalog.') unless source_item

    # Do not accept malformed rows carrying both platforms' identities.
    levels = @levels_by_item.fetch(source_item.id, [])
    unless levels.one? && levels.first[@opposite].nil? && !levels.first.quantity.nil?
      return unavailable.call('No unambiguous stored stock row exists for this platform, location and item.')
    end

    level = levels.first
    quantity = level.quantity
    metadata.merge!('status' => 'matched', 'source_item_id' => source_item.id,
      'inventory_level_id' => level.id, 'mirrored_at' => level.updatedAt&.iso8601(6),
      'quantity_basis' => 'in_stock')
    { @key => source_item.id, previousQuantity: quantity, comparison_snapshot: metadata }
  end

  def prepared_items
    return @native.prepared_items if @native

    return [] unless @ids_by_sku

    @ids_by_sku.keys.sort.filter_map do |sku|
      item = InventoryCountItem.new(sku: sku)
      attributes = attributes_for(item)
      next unless attributes[:comparison_snapshot]['status'] == 'matched'

      source_item = @source_items[attributes[@key]]
      item.square_variation = source_item
      # Physical counts cannot be negative even when available stock is oversold.
      item.assign_attributes(attributes.merge(quantity: [attributes[:previousQuantity], 0].max))
      item
    end
  end
end
