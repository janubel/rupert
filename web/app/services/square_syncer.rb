# frozen_string_literal: true

# Port of pullSquare + the Square half of the seed script — mirrors the
# Square catalog, locations, inventory counts, and SKU links into the
# database, journaling quantity changes as movements.
class SquareSyncer
  class << self
    include SyncConcern

    # Returns { items:, variations:, levels:, links:, orders:, locations: }
    def sync!(since: nil)
      locations = SquareClient.locations
      primary = pick_primary_location(locations)
      raise SquareClient::Error, 'Square: no active location found' if primary.nil?

      catalog = SquareClient.catalog
      counts = SquareClient.inventory_counts(locations.map { |l| l['id'] }, catalog.map { |v| v[:variationId] })
      orders = SquareClient.orders(
        locations.map { |l| l['id'] },
        since || (Time.current - history_lookback).iso8601
      )

      sync_locations!(locations, catalog, counts, primary)
      { items: 0, variations: 0, levels: 0, links: 0, orders: orders, locations: locations }
    end

    def primary_location_id
      preferred = EnvStore.fetch('SQUARE_LOCATION_ID', '')
      location = preferred.present? ? Location.find_by(source: 'square', externalId: preferred) : nil
      location || Location.square_primary
    end

    private

    def pick_primary_location(locations)
      preferred = EnvStore.fetch('SQUARE_LOCATION_ID', '')
      locations.find { |l| l['id'] == preferred } || locations.first
    end

    def sync_locations!(locations, catalog, counts, primary)
      sync_catalog!(catalog)
      sync_links!(catalog)
      sync_levels!(locations, catalog, counts, primary)
    end

    def sync_catalog!(catalog)
      now = Time.current
      item_rows = {}
      variation_rows = []
      catalog.each do |variation|
        # Bulk writes skip callbacks, so rows carry tenant_id explicitly.
        item_rows[variation[:itemId]] ||= {
          id: variation[:itemId], name: variation[:name], syncedAt: now, tenant_id: Current.tenant_id
        }
        variation_rows << {
          id: variation[:variationId], itemId: variation[:itemId], sku: variation[:sku],
          name: variation[:name], syncedAt: now, tenant_id: Current.tenant_id
        }
      end

      SquareItem.upsert_all(item_rows.values, unique_by: :id) if item_rows.any?
      SquareVariation.upsert_all(variation_rows, unique_by: :id) if variation_rows.any?
    end

    def sync_links!(catalog)
      CatalogMappingLock.synchronize do
        normalize = ->(sku) { sku.to_s.strip.downcase.presence }
        replaceable = ->(link) { link.auto == true && link.matchSource == 'sku' }
        variants = ShopifyVariant.includes(:product).to_a
        shopify_by_sku = variants.group_by { |variant| normalize.call(variant.sku) }
        variant_ids = variants.index_by(&:id)
        square_by_sku = catalog.group_by { |variation| normalize.call(variation[:sku]) }
        square_skus_by_id = catalog.group_by { |variation| variation[:variationId] }
          .transform_values { |rows| rows.map { |row| normalize.call(row[:sku]) }.uniq }
        known_square_ids = SquareVariation.where(id: catalog.filter_map { |row| row[:variationId] }).pluck(:id).index_with(true)
        existing_links = SkuLink.all.index_by(&:shopifyVariantId)
        explicit_targets = existing_links.values.reject { |link| replaceable.call(link) }
          .select { |link| link.squareVariationId.present? }.group_by(&:squareVariationId)
        links = 0

        variants.each do |variant|
          link = existing_links[variant.id]
          # A sync cannot replace a deliberate operator/audit mapping, including
          # when the catalog SKU has subsequently changed.
          next if link && !replaceable.call(link)

          sku = normalize.call(variant.sku)
          candidates = Array(square_by_sku[sku]).filter_map { |row| row[:variationId].presence }.uniq
          wholesale = variant.product&.tags.to_s.split(',').map(&:strip).include?('wholesale')
          target = if sku && shopify_by_sku.fetch(sku).one? && candidates.one? && !wholesale &&
                      known_square_ids.key?(candidates.first) && square_skus_by_id.fetch(candidates.first).one? &&
                      Array(explicit_targets[candidates.first]).none? { |owner| owner.shopifyVariantId != variant.id }
            candidates.first
          end

          if link
            if link.squareVariationId == target && (target.nil? || link.sku == variant.sku)
              links += 1 if target
              next
            end

            changes = { squareVariationId: target }
            changes[:sku] = variant.sku if variant.sku.present?
            # Condition on the original automatic state in SQL: a manual save
            # after the snapshot above must win over this stale sync object.
            updated = SkuLink.where(id: link.id, auto: true, matchSource: 'sku').update_all(changes)
            links += 1 if target && updated == 1
          elsif target
            begin
              SkuLink.transaction(requires_new: true) do
                SkuLink.create!(tenant_id: Current.tenant_id, shopifyVariantId: variant.id,
                  squareVariationId: target, sku: variant.sku, matchSource: 'sku', auto: true,
                  createdAt: Time.current)
              end
              links += 1
            rescue ActiveRecord::RecordNotUnique
              # A concurrently created operator link owns the unique variant key.
              # Leave it intact; a later sync can reconsider an automatic row.
              next
            end
          end
        end

        # A dangling automatic mapping is unresolved, rather than a claim that
        # the removed Shopify item still identifies a Square stock pool.
        orphan_ids = existing_links.values.select { |link| replaceable.call(link) }
          .reject { |link| variant_ids.key?(link.shopifyVariantId) }.map(&:id)
        SkuLink.where(id: orphan_ids, auto: true, matchSource: 'sku').update_all(squareVariationId: nil) if orphan_ids.any?
        links
      end
    end

    def sync_levels!(locations, catalog, counts, _primary)
      now = Time.current
      location_records = locations.map do |location|
        upsert_location(
          source: 'square',
          external_id: location['id'],
          name: location['name'],
          kind: location['type'],
          timezone: location['timezone']
        )
      end

      # Desired per-location rows, diffed against existing levels loaded once,
      # then written as one upsert + one movement insert (same shape as the
      # Shopify side).
      desired = []
      location_records.each do |location_record|
        by_variation = counts[:counts_by_location][location_record.externalId] || Hash.new(0)
        catalog.each do |variation|
          quantity = by_variation[variation[:variationId]]
          next if quantity.nil?

          desired << {
            location_id: location_record.id,
            variation_id: variation[:variationId],
            sku: variation[:sku],
            quantity: quantity
          }
        end
      end
      return if desired.empty?

      existing = InventoryLevel.mirrored('square')
                               .where(squareVariationId: desired.map { |d| d[:variation_id] })
                               .index_by do |level|
        [level.locationId,
         level.squareVariationId]
      end

      level_rows = desired.map do |d|
        old = existing[[d[:location_id], d[:variation_id]]]
        {
          id: old&.id || HasCuid.generate,
          source: 'square',
          locationId: d[:location_id],
          squareVariationId: d[:variation_id],
          quantity: d[:quantity],
          available: d[:quantity],
          updatedAt: now,
          tenant_id: Current.tenant_id
        }
      end

      movement_rows = desired.filter_map do |d|
        before = existing[[d[:location_id], d[:variation_id]]]&.quantity || 0
        next if before == d[:quantity]

        {
          id: HasCuid.generate,
          sku: d[:sku],
          squareVariationId: d[:variation_id],
          source: 'square',
          direction: 'set',
          delta: d[:quantity] - before,
          quantityBefore: before,
          quantityAfter: d[:quantity],
          reason: 'Synced from Square',
          reference: 'sync',
          actor: 'system',
          syncRunId: Current.sync_run_id,
          createdAt: now,
          tenant_id: Current.tenant_id
        }
      end

      ActiveRecord::Base.transaction do
        InventoryLevel.upsert_all(level_rows, unique_by: :idx_inventory_levels_tenant_source_loc_square)
        InventoryMovement.insert_all(movement_rows) if movement_rows.any?
      end
    end
  end
end
