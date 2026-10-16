# frozen_string_literal: true

require 'bigdecimal'

module Ctrax
  class CountComparison
    def initialize(count)
      @count = count
      @location = Location.find_by(id: count.locationId, tenant_id: count.tenant_id, source: 'ctrax')
      @snapshot = CtraxStockSnapshot.find_by(tenant_id: count.tenant_id, location_id: @location.id) if @location
      @records = @snapshot&.records || []
      @by_id = @records.index_by { |record| record['id'] }
      @by_sku = @records.select { |record| record['sku'].present? }.group_by { |record| record['sku'] }
      @duplicates = count.new_record? ? [] : count.items.group(:sku).count.select { |_, n| n > 1 }.keys
      ids = count.items.map { |item| matches(item.sku).one? ? matches(item.sku).first['id'] : nil }.compact
      @shared_ids = ids.tally.select { |_, n| n > 1 }.keys
    end

    def attributes_for(item)
      metadata = { 'status' => 'unavailable', 'source' => 'ctrax', 'location_id' => @location&.id,
                   'location_name' => @location&.name, 'captured_at' => Time.current.iso8601(6) }
      unavailable = ->(reason) { { previousQuantity: nil, comparison_snapshot: metadata.merge('reason' => reason) } }
      return unavailable.call('No C-Trax snapshot exists for this store.') unless @snapshot
      if @duplicates.include?(item.sku)
        return unavailable.call('Duplicate worksheet rows cannot share one C-Trax stock pool.')
      end

      candidates = matches(item.sku)
      return unavailable.call('Use one unambiguous C-Trax variant or SKU at this store.') unless candidates.one?

      record = candidates.first
      if @shared_ids.include?(record['id'])
        return unavailable.call('Multiple worksheet rows identify the same C-Trax variant.')
      end
      if item.comparison['source_item_id'].present? && item.comparison['source_item_id'] != record['id']
        return unavailable.call('The C-Trax variant identity changed. Review this row.')
      end
      return unavailable.call('Stock tracking is not verified for this C-Trax variant.') unless record['manage_stock']
      return unavailable.call('C-Trax did not supply stock for this variant.') if record['quantity'].nil?

      quantity = BigDecimal(record['quantity'])
      unless quantity.frac.zero? && quantity.between?(-2_147_483_648, 2_147_483_647)
        return unavailable.call('This worksheet supports whole units only; C-Trax stock is fractional or outside its range.')
      end

      metadata.merge!('status' => 'matched', 'source_item_id' => record['id'], 'source_store_id' => @snapshot.store_id,
        'api_origin' => @snapshot.api_origin, 'stock_snapshot_id' => @snapshot.id, 'source_sku' => record['sku'],
        'product_name' => record['name'], 'quantity_basis' => 'store_stock', 'mirrored_at' => @snapshot.captured_at.iso8601(6))
      { previousQuantity: quantity.to_i, comparison_snapshot: metadata }
    end

    def prepared_items
      @records.filter_map do |record|
        item = InventoryCountItem.new(sku: "ctrax:#{record['id']}")
        attributes = attributes_for(item)
        next unless attributes[:comparison_snapshot]['status'] == 'matched'

        item.assign_attributes(attributes.merge(quantity: [attributes[:previousQuantity], 0].max))
        item
      end
    end

    def resolve!(code)
      raise InventoryCountScan::Error, 'Scan a code of between 1 and 255 characters.' if code.blank? || code.length > 255

      candidates = @records.select do |record|
        ["ctrax:#{record['id']}", record['sku'], record['barcode']].compact.include?(code)
      end
      unless candidates.one?
        raise InventoryCountScan::Error.new(
          'Scan does not identify one C-Trax variant at this store. Use its prepared count row.', status: :conflict
        )
      end

      record = candidates.first
      { sku: "ctrax:#{record['id']}", title: record['name'].presence || "C-Trax variant #{record['id']}" }
    end

    def canonical_key(key)
      candidates = matches(key)
      candidates.one? ? "ctrax:#{candidates.first['id']}" : key
    end

    private

    def matches(key)
      # Native keys remain usable when the source has no SKU. A colliding real
      # SKU is ambiguous rather than silently selecting a different stock pool.
      native = key.start_with?('ctrax:') ? @by_id[key.delete_prefix('ctrax:')] : nil
      ([native] + @by_sku.fetch(key, [])).compact.uniq
    end
  end
end
