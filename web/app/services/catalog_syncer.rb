# frozen_string_literal: true

# Port of pullShopify + the Shopify half of the seed script — mirrors the
# Shopify product catalog, variants, locations, and inventory levels into
# the database, journaling quantity changes as movements.
class CatalogSyncer
  SHOP_QUERY = <<~GRAPHQL
    query Shop {
      shop { name myshopifyDomain currencyCode }
    }
  GRAPHQL

  # Products are fetched with full cursor pagination (a bare `first: 250`
  # silently truncated catalogs beyond one page). NOTE: no inventoryLevels here
  # — nesting per-variant levels inside the catalog query pushes its computed
  # GraphQL cost past Shopify's single-query max (1000) and fails every sync.
  # Per-location quantities come from INVENTORY_LEVELS_QUERY instead, keyed by
  # the variant's inventoryItemId.
  PRODUCTS_QUERY = <<~GRAPHQL
    query Products($cursor: String) {
      products(first: 250, query: "status:active", sortKey: TITLE, after: $cursor) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id title tags status handle publishedAt totalInventory
          featuredImage { url altText }
          variants(first: 100) { nodes { id title sku price inventoryQuantity inventoryItem { id tracked } } }
        }
      }
    }
  GRAPHQL

  # Per-location "available" quantities are fetched SEPARATELY from the catalog
  # (nesting them there exceeds Shopify's single-query cost max). There is no
  # ids-filtered connection for this API version, so we batch aliased singular
  # inventoryItem lookups instead — LEVELS_BATCH caps each request's computed
  # cost well under the limit.
  LEVELS_BATCH = 30

  LOCATIONS_QUERY = <<~GRAPHQL
    query Locations { locations(first: 10) { nodes { id name isActive } } }
  GRAPHQL

  # Paginates every order matching the query, so the sync captures the full
  # history window rather than the first page. Keep order pages small because
  # each exact variant identity is nested inside up to 100 line items.
  ORDERS_QUERY = <<~GRAPHQL
    query Orders($orderQuery: String!, $orderCursor: String) {
      orders(first: 5, query: $orderQuery, sortKey: CREATED_AT, reverse: true, after: $orderCursor) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id name createdAt cancelledAt displayFinancialStatus paymentGatewayNames
          currentTotalPriceSet { shopMoney { amount currencyCode } }
          currentTotalTaxSet { shopMoney { amount currencyCode } }
          customer { id email firstName lastName phone }
          shippingAddress {
            address1 address2 city country province zip phone
          }
          fulfillments {
            id status createdAt updatedAt
            trackingInfo { company number url }
          }
          lineItems(first: 100) {
            pageInfo { hasNextPage }
            nodes {
              id title variantTitle sku quantity currentQuantity
              variant { id }
              originalUnitPriceSet { shopMoney { amount currencyCode } }
              originalTotalSet { shopMoney { amount currencyCode } }
            }
          }
        }
      }
    }
  GRAPHQL

  THRESHOLD = 5

  class << self
    include SyncConcern

    # Returns { products:, variants:, locations:, orders:, shop: }
    def sync!(since: nil)
      since ||= (Time.current - history_lookback).strftime('%Y-%m-%d')
      location_nodes = fetch_locations
      sync_locations!(location_nodes)
      assign_shopify_primary!(location_nodes)

      # Shopify levels mirror PER LOCATION now (same as Square): keyed by the
      # Location record id, quantity = that location's "available" count.
      # The variant's inventoryQuantity total is still stored on ShopifyVariant.
      product_pages = paginate_products
      variant_nodes = product_pages.flat_map { |p| Array(p.dig('variants', 'nodes')) }
      levels_by_item_id = fetch_inventory_levels(variant_nodes.map { |v| v.dig('inventoryItem', 'id') })

      locations_by_gid = Location.by_source('shopify')
                                 .index_by(&:externalId)
      primary = Location.shopify_primary ||
                Location.find_by(source: 'shopify', externalId: 'default')

      counts = sync_products!(product_pages, levels_by_item_id, locations_by_gid, primary)
      {
        products: counts[:products],
        variants: counts[:variants],
        oversold_variants: counts[:oversold_variants],
        locations: location_nodes,
        orders: paginate_orders(since),
        shop: ShopifyClient.graphql(SHOP_QUERY, {})['shop']
      }
    end

    private

    # Fetches every ACTIVE product, following the cursor until exhausted.
    # Returns the flat array of product nodes for sync_products!.
    def paginate_products
      nodes = []
      cursor = nil
      loop do
        data = ShopifyClient.graphql(PRODUCTS_QUERY, { cursor: cursor })
        page = data['products']
        nodes.concat(page['nodes'] || [])
        info = page['pageInfo'] || {}
        break unless info['hasNextPage'] && info['endCursor']

        cursor = info['endCursor']
      end
      nodes
    end

    # Per-location "available" levels for the given inventory item ids, keyed
    # by item id. Batched aliased lookups (see LEVELS_BATCH note); unknown ids
    # simply come back nil and are skipped.
    def fetch_inventory_levels(item_ids)
      result = Hash.new { |hash, key| hash[key] = [] }
      item_ids.compact.uniq.each_slice(LEVELS_BATCH) do |batch|
        variables = batch.each_with_index.to_h { |id, i| ["v#{i}", id] }
        data = ShopifyClient.graphql(levels_query(batch.length), variables)
        batch.each_with_index do |id, i|
          item = data["v#{i}"]
          next if item.nil?

          result[id] += Array(item.dig('inventoryLevels', 'nodes'))
        end
      end
      result
    end

    def levels_query(count)
      variables = (0...count).map { |i| "$v#{i}: ID!" }.join(', ')
      fields = (0...count).map do |i|
        <<~G.squish
          v#{i}: inventoryItem(id: $v#{i}) { id inventoryLevels(first: 10) { nodes { location { id } quantities(names: ["available"]) { name quantity } } } }
        G
      end.join(' ')
      "query Levels(#{variables}) { #{fields} }"
    end

    # Fetches every order in the window, following the cursor until exhausted.
    # Returns the raw GraphQL "orders" object ({ nodes:, pageInfo: }).
    def paginate_orders(since)
      nodes = []
      cursor = nil
      loop do
        data = ShopifyClient.graphql(ORDERS_QUERY, { orderQuery: "created_at:>=#{since}", orderCursor: cursor })
        page = data['orders']
        nodes.concat(page['nodes'] || [])
        info = page['pageInfo'] || {}
        break unless info['hasNextPage'] && info['endCursor']

        cursor = info['endCursor']
      end
      { 'nodes' => nodes, 'pageInfo' => { 'hasNextPage' => false, 'endCursor' => cursor } }
    end

    def fetch_locations
      ShopifyClient.graphql(LOCATIONS_QUERY, {})['locations']['nodes']
    end

    def sync_locations!(nodes)
      if nodes.empty?
        upsert_location(source: 'shopify', external_id: 'default', name: 'Shopify Online Store', kind: 'VIRTUAL')
      else
        nodes.each do |location|
          upsert_location(
            source: 'shopify',
            external_id: location['id'],
            name: location['name'],
            kind: 'RETAIL',
            active: location['isActive'] != false
          )
        end
      end
    end

    # Flags exactly one Shopify location as primary: SHOPIFY_LOCATION_ID if set,
    # else the first ACTIVE location in the API's order (the online store is
    # usually first), else the first known row. Deterministic — the previous
    # "oldest syncedAt wins" pick broke once more than one location existed.
    def assign_shopify_primary!(location_nodes)
      preferred_gid = EnvStore.fetch('SHOPIFY_LOCATION_ID', '').presence
      gids = location_nodes.map { |node| node['id'] }
      active_gids = location_nodes.select { |node| node['isActive'] != false }.map { |node| node['id'] }
      chosen_gid =
        (preferred_gid if gids.include?(preferred_gid)) ||
        active_gids.first ||
        gids.first

      chosen = chosen_gid.present? ? Location.find_by(source: 'shopify', externalId: chosen_gid) : nil
      return if chosen.nil?

      Location.by_source('shopify').where(primary_location: true).where.not(id: chosen.id)
              .update_all(primary_location: false)
      chosen.update_column(:primary_location, true) unless chosen.primary_location?
      chosen
    end

    def sync_products!(products, levels_by_item_id, locations_by_gid, primary)
      now = Time.current
      product_rows = []
      variant_rows = []
      variant_nodes = []
      oversold = 0

      products.each do |product|
        product_rows << {
          id: product['id'],
          title: product['title'],
          status: product['status'],
          handle: product['handle'],
          publishedAt: parse_time(product['publishedAt']),
          totalInventory: product['totalInventory'].to_i,
          featuredImageUrl: product.dig('featuredImage', 'url'),
          tags: Array(product['tags']).join(', '),
          syncedAt: now,
          tenant_id: Current.tenant_id
        }
        Array(product.dig('variants', 'nodes')).each do |node|
          raw_qty = node['inventoryQuantity'].to_i
          # Only TRACKED variants can oversell; untracked items just carry a
          # stale historical quantity that Shopify keeps reporting.
          oversold += 1 if raw_qty.negative? && node.dig('inventoryItem', 'tracked')
          variant_rows << build_variant_row(product['id'], node, now)
          variant_nodes << node
        end
      end

      if oversold.positive?
        Rails.logger.warn("CatalogSyncer: #{oversold} Shopify variants are oversold (negative stock) — mirrored as 0. See NegativeInventory / restock queue.")
      end

      # One statement per table per sync instead of one upsert per row; rows
      # carry tenant_id explicitly because bulk writes skip callbacks (and
      # TenantScoped's assign_tenant with them).
      ActiveRecord::Base.transaction do
        ShopifyProduct.upsert_all(product_rows, unique_by: :id) if product_rows.any?
        ShopifyVariant.upsert_all(variant_rows, unique_by: :id) if variant_rows.any?
        sync_levels_batched!(variant_nodes, levels_by_item_id, locations_by_gid, primary, now)
      end

      prune_stale_shopify_levels!
      { products: product_rows.length, variants: variant_rows.length, oversold_variants: oversold }
    end

    def build_variant_row(product_id, variant, now)
      # Mirrored inventory stays non-negative: oversold Shopify counts are
      # zeroed locally (the negative-inventory remediation) instead of being
      # pushed back to Shopify. Reconcile therefore sees 0 for these SKUs.
      quantity = [variant['inventoryQuantity'].to_i, 0].max
      item = variant['inventoryItem'] || {}

      {
        id: variant['id'],
        productId: product_id,
        title: variant['title'],
        sku: variant['sku'],
        price: variant['price']&.to_f,
        inventoryQuantity: quantity,
        tracked: item['tracked'] == true,
        inventoryItemId: item['id'],
        syncedAt: now,
        tenant_id: Current.tenant_id
      }
    end

    # One mirrored level PER Shopify location (like the Square side), keyed by
    # the Location record id so level.location resolves and per-location stock
    # is answerable. Aggregated readers (totals, dashboards, PDF) sum across
    # rows, so their numbers are unchanged.
    #
    # Batched: desired rows are diffed against the existing levels loaded once,
    # then written as a single level upsert + movements insert inside the
    # caller's transaction. Quantity changes journal before -> after exactly as
    # the per-row version did.
    def sync_levels_batched!(variant_nodes, levels_by_item_id, locations_by_gid, primary, now)
      desired = []
      variant_nodes.each do |variant|
        variant_id = variant['id']
        sku = variant['sku']
        item = variant['inventoryItem'] || {}
        quantity = [variant['inventoryQuantity'].to_i, 0].max

        level_nodes = levels_by_item_id[item['id']] || []
        if level_nodes.empty?
          # Untracked items / shapes without level data: keep the variant total
          # on the primary row so the item still surfaces in views and alerts.
          next if primary.nil?

          desired << { location_id: primary.id, variant_id: variant_id, sku: sku, quantity: quantity }
        else
          level_nodes.each do |node|
            location = locations_by_gid[node.dig('location', 'id')]
            next if location.nil?

            available = Array(node['quantities']).find { |q| q['name'] == 'available' }&.dig('quantity').to_i
            desired << { location_id: location.id, variant_id: variant_id, sku: sku, quantity: [available, 0].max }
          end
        end
      end
      return if desired.empty?

      existing = InventoryLevel.mirrored('shopify')
                               .where(shopifyVariantId: desired.map { |d| d[:variant_id] })
                               .index_by do |level|
        [level.locationId,
         level.shopifyVariantId]
      end

      level_rows = desired.map do |d|
        old = existing[[d[:location_id], d[:variant_id]]]
        {
          id: old&.id || HasCuid.generate,
          source: 'shopify',
          locationId: d[:location_id],
          shopifyVariantId: d[:variant_id],
          quantity: d[:quantity],
          available: d[:quantity],
          updatedAt: now,
          tenant_id: Current.tenant_id
        }
      end

      movement_rows = desired.filter_map do |d|
        before = existing[[d[:location_id], d[:variant_id]]]&.quantity || 0
        next if before == d[:quantity]

        {
          id: HasCuid.generate,
          sku: d[:sku],
          shopifyVariantId: d[:variant_id],
          source: 'shopify',
          direction: 'set',
          delta: d[:quantity] - before,
          quantityBefore: before,
          quantityAfter: d[:quantity],
          reason: 'Synced from Shopify',
          reference: 'sync',
          actor: 'system',
          syncRunId: Current.sync_run_id,
          createdAt: now,
          tenant_id: Current.tenant_id
        }
      end

      InventoryLevel.upsert_all(level_rows, unique_by: :idx_inventory_levels_tenant_source_loc_shopify)
      InventoryMovement.insert_all(movement_rows) if movement_rows.any?
    end

    # Deletes mirrored Shopify levels whose location no longer exists (a
    # location was deactivated/removed on Shopify). Guarded: if NO shopify
    # locations are known — e.g. a transient API failure earlier in the run —
    # nothing is deleted. Stale rows are dropped without journaling; they were
    # mirror bookkeeping for a location that no longer exists, not real stock.
    def prune_stale_shopify_levels!
      known_ids = Location.by_source('shopify').pluck(:id)
      return 0 if known_ids.empty?

      removed = InventoryLevel.mirrored('shopify').where.not(locationId: known_ids).delete_all
      Rails.logger.info("CatalogSyncer: pruned #{removed} stale Shopify inventory level rows") if removed.positive?
      removed
    end

    def parse_time(value)
      value.present? ? Time.zone.parse(value) : nil
    end
  end
end
