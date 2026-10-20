# frozen_string_literal: true

require 'test_helper'

class CatalogSyncerTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
    EnvStore.clear_cache!
    EnvStore::MANAGED_KEYS.freeze unless EnvStore::MANAGED_KEYS.frozen?
  end

  teardown do
    Setting.where(key: 'SYNC_HISTORY_DAYS').delete_all
    EnvStore.clear_cache!
    Current.tenant = nil
  end

  test 'history_lookback defaults to 30 days when unset' do
    assert_equal 30.days, CatalogSyncer.send(:history_lookback)
  end

  test 'history_lookback honors SYNC_HISTORY_DAYS' do
    EnvStore.set('SYNC_HISTORY_DAYS', '3650')
    assert_equal 3650.days, CatalogSyncer.send(:history_lookback)
  end

  test 'orders are selected by updated_at so later refunds and cancellations are re-read' do
    captured = []
    ShopifyClient.stubs(:graphql).with { |query, variables| captured.push([query, variables]) }
                 .returns({ 'orders' => { 'nodes' => [], 'pageInfo' => { 'hasNextPage' => false } } })
    CatalogSyncer.send(:paginate_orders, '2026-01-01')
    query, variables = captured.first
    assert_equal 'updated_at:>=2026-01-01', variables[:orderQuery]
    assert_includes query, 'sortKey: UPDATED_AT'
    assert_includes query, 'refunds { id createdAt totalRefundedSet'
  end

  test 'paginate_orders walks all pages' do
    page1 = { 'orders' => { 'nodes' => [{ 'id' => 'a' }, { 'id' => 'b' }],
                            'pageInfo' => { 'hasNextPage' => true, 'endCursor' => 'c1' } } }
    page2 = { 'orders' => { 'nodes' => [{ 'id' => 'c' }],
                            'pageInfo' => { 'hasNextPage' => false, 'endCursor' => 'c2' } } }

    ShopifyClient.stubs(:graphql)
                 .returns(page1)
                 .then.returns(page2)

    result = CatalogSyncer.send(:paginate_orders, '2026-01-01')

    assert_equal(%w[a b c], result['nodes'].map { |n| n['id'] })
    refute result['pageInfo']['hasNextPage']
  end

  test 'paginate_products walks all pages instead of truncating at 250' do
    page1 = { 'products' => { 'nodes' => [{ 'id' => 'p1', 'variants' => { 'nodes' => [], 'pageInfo' => { 'hasNextPage' => false } } }, { 'id' => 'p2', 'variants' => { 'nodes' => [], 'pageInfo' => { 'hasNextPage' => false } } }],
                              'pageInfo' => { 'hasNextPage' => true, 'endCursor' => 'c1' } } }
    page2 = { 'products' => { 'nodes' => [{ 'id' => 'p3', 'variants' => { 'nodes' => [], 'pageInfo' => { 'hasNextPage' => false } } }],
                              'pageInfo' => { 'hasNextPage' => false, 'endCursor' => 'c2' } } }

    ShopifyClient.stubs(:graphql)
                 .returns(page1)
                 .then.returns(page2)

    result = CatalogSyncer.send(:paginate_products)

    assert_equal(%w[p1 p2 p3], result.map { |n| n['id'] })
  end

  test 'sync_levels_batched! mirrors one level per Shopify location' do
    home = Location.create!(source: 'shopify', externalId: 'gid://shopify/Location/1', name: 'Online')
    rig = Location.create!(source: 'shopify', externalId: 'gid://shopify/Location/2', name: 'Market Rig')

    variant = {
      'id' => 'gid://shopify/ProductVariant/9',
      'title' => 'Tea / 50g',
      'sku' => 'TEA-50',
      'price' => '12.00',
      'inventoryQuantity' => 7,
      'inventoryItem' => { 'id' => 'gid://shopify/InventoryItem/9', 'tracked' => true }
    }
    levels = {
      'gid://shopify/InventoryItem/9' => [
        { 'location' => { 'id' => 'gid://shopify/Location/1' },
          'quantities' => [{ 'name' => 'available', 'quantity' => 5 }] },
        { 'location' => { 'id' => 'gid://shopify/Location/2' },
          'quantities' => [{ 'name' => 'available', 'quantity' => 2 }] }
      ]
    }

    ShopifyProduct.create!(id: 'gid://shopify/Product/1', title: 'Tea')
    ShopifyVariant.create!(id: variant['id'], productId: 'gid://shopify/Product/1', title: 'Tea / 50g', sku: 'TEA-50')

    CatalogSyncer.send(:sync_levels_batched!, [variant], levels,
      { 'gid://shopify/Location/1' => home, 'gid://shopify/Location/2' => rig }, home, Time.current)

    levels = InventoryLevel.where(source: 'shopify', shopifyVariantId: variant['id'])
    assert_equal 2, levels.count
    assert_equal 5, levels.find_by(locationId: home.id).quantity
    assert_equal 2, levels.find_by(locationId: rig.id).quantity
    # Rows are keyed by the Location record id so level.location resolves.
    assert_equal home.id, levels.find_by(locationId: home.id).location&.id
    # Quantity changes journal movements.
    assert_equal 2, InventoryMovement.where(shopifyVariantId: variant['id']).count
  end

  test 'sync_levels_batched! falls back to the primary row when no levels are returned' do
    primary = Location.create!(source: 'shopify', externalId: 'gid://shopify/Location/1', name: 'Online')

    variant = {
      'id' => 'gid://shopify/ProductVariant/10',
      'title' => 'Poster',
      'sku' => nil,
      'inventoryQuantity' => 3,
      'inventoryItem' => { 'id' => 'gid://shopify/InventoryItem/10', 'tracked' => false }
    }
    levels = {}

    ShopifyProduct.create!(id: 'gid://shopify/Product/2', title: 'Poster')
    ShopifyVariant.create!(id: variant['id'], productId: 'gid://shopify/Product/2', title: 'Poster', sku: nil)

    CatalogSyncer.send(:sync_levels_batched!, [variant], levels, {}, primary, Time.current)

    levels = InventoryLevel.where(source: 'shopify', shopifyVariantId: variant['id'])
    assert_equal 1, levels.count
    assert_equal 3, levels.find_by(locationId: primary.id).quantity
  end

  test 'sync_levels_batched! is idempotent — reruns update in place without duplicate movements' do
    home = Location.create!(source: 'shopify', externalId: 'gid://shopify/Location/1', name: 'Online')
    variant = {
      'id' => 'gid://shopify/ProductVariant/11',
      'title' => 'Tea / 50g',
      'sku' => 'TEA-50',
      'inventoryQuantity' => 5,
      'inventoryItem' => { 'id' => 'gid://shopify/InventoryItem/11', 'tracked' => true }
    }
    levels = {
      'gid://shopify/InventoryItem/11' => [
        { 'location' => { 'id' => 'gid://shopify/Location/1' },
          'quantities' => [{ 'name' => 'available', 'quantity' => 5 }] }
      ]
    }
    locations = { 'gid://shopify/Location/1' => home }
    ShopifyProduct.create!(id: 'gid://shopify/Product/3', title: 'Tea')
    ShopifyVariant.create!(id: variant['id'], productId: 'gid://shopify/Product/3', title: 'Tea / 50g', sku: 'TEA-50')

    2.times { CatalogSyncer.send(:sync_levels_batched!, [variant], levels, locations, home, Time.current) }

    assert_equal 1, InventoryLevel.where(source: 'shopify', shopifyVariantId: variant['id']).count
    assert_equal 1, InventoryMovement.where(shopifyVariantId: variant['id']).count # only the initial 0->5
  end

  test 'prune_stale_shopify_levels! removes rows for vanished locations and guards an empty map' do
    known = Location.create!(source: 'shopify', externalId: 'gid://shopify/Location/1', name: 'Online')
    variant = ShopifyVariant.create!(productId: 'p-x', title: 'X', sku: 'X-1')
    InventoryLevel.create!(source: 'shopify', locationId: known.id, shopifyVariantId: variant.id, quantity: 1)
    stale = InventoryLevel.create!(source: 'shopify', locationId: 'c-gone-location', shopifyVariantId: variant.id,
      quantity: 4)

    assert_equal 1, CatalogSyncer.send(:prune_stale_shopify_levels!)
    assert_not InventoryLevel.exists?(stale.id)
    assert InventoryLevel.where(source: 'shopify', locationId: known.id).exists?

    # Transient API failure left us with zero known locations — never bulk-delete.
    Location.by_source('shopify').delete_all
    InventoryLevel.create!(source: 'shopify', locationId: 'c-another', shopifyVariantId: variant.id, quantity: 2)
    assert_equal 0, CatalogSyncer.send(:prune_stale_shopify_levels!)
  end

  test 'assign_shopify_primary! flags the first active location and honors SHOPIFY_LOCATION_ID' do
    a = Location.create!(source: 'shopify', externalId: 'gid://shopify/Location/1', name: 'Online')
    b = Location.create!(source: 'shopify', externalId: 'gid://shopify/Location/2', name: 'Rig')

    nodes = [
      { 'id' => 'gid://shopify/Location/1', 'isActive' => true },
      { 'id' => 'gid://shopify/Location/2', 'isActive' => true }
    ]
    CatalogSyncer.send(:assign_shopify_primary!, nodes)
    assert_predicate a.reload, :primary_location?
    refute b.reload.primary_location?
    assert_equal a.id, Location.shopify_primary.id

    # An explicit pin moves the flag; the old flag is cleared.
    EnvStore.set('SHOPIFY_LOCATION_ID', 'gid://shopify/Location/2')
    CatalogSyncer.send(:assign_shopify_primary!, nodes)
    assert_equal b.id, Location.shopify_primary.id
    refute a.reload.primary_location?
  ensure
    Setting.where(key: 'SHOPIFY_LOCATION_ID').delete_all
    EnvStore.instance_variable_set(:@cache, {}) if EnvStore.instance_variable_defined?(:@cache)
  end

  test 'paginate_products follows variants beyond the first 100 of a product' do
    first_variants = [{ 'id' => 'v1' }, { 'id' => 'v2' }]
    page = { 'products' => { 'nodes' => [{ 'id' => 'p1', 'variants' => {
      'nodes' => first_variants, 'pageInfo' => { 'hasNextPage' => true, 'endCursor' => 'vc1' } } }],
                             'pageInfo' => { 'hasNextPage' => false, 'endCursor' => nil } } }
    more = { 'product' => { 'variants' => { 'nodes' => [{ 'id' => 'v3' }],
                                            'pageInfo' => { 'hasNextPage' => false, 'endCursor' => nil } } } }
    ShopifyClient.stubs(:graphql).returns(page).then.returns(more)

    product = CatalogSyncer.send(:paginate_products).first

    assert_equal(%w[v1 v2 v3], product.dig('variants', 'nodes').map { |v| v['id'] })
  end

  test 'fetch_locations follows every page instead of stopping at a fixed count' do
    page1 = { 'locations' => { 'nodes' => [{ 'id' => 'l1' }], 'pageInfo' => { 'hasNextPage' => true, 'endCursor' => 'c1' } } }
    page2 = { 'locations' => { 'nodes' => [{ 'id' => 'l2' }], 'pageInfo' => { 'hasNextPage' => false, 'endCursor' => nil } } }
    ShopifyClient.stubs(:graphql).returns(page1).then.returns(page2)

    assert_equal(%w[l1 l2], CatalogSyncer.send(:fetch_locations).map { |l| l['id'] })
  end

  test 'fetch_inventory_levels follows an items locations past the first page' do
    item = 'gid://shopify/InventoryItem/1'
    batch = { 'v0' => { 'id' => item, 'inventoryLevels' => {
      'nodes' => [{ 'location' => { 'id' => 'l1' } }], 'pageInfo' => { 'hasNextPage' => true, 'endCursor' => 'lc1' } } } }
    rest = { 'inventoryItem' => { 'inventoryLevels' => {
      'nodes' => [{ 'location' => { 'id' => 'l2' } }], 'pageInfo' => { 'hasNextPage' => false, 'endCursor' => nil } } } }
    ShopifyClient.stubs(:graphql).returns(batch).then.returns(rest)

    levels = CatalogSyncer.send(:fetch_inventory_levels, [item])

    assert_equal(%w[l1 l2], levels[item].map { |n| n.dig('location', 'id') })
  end

  test 'sync_levels_batched! keeps the raw platform quantity when stock is oversold' do
    home = Location.create!(source: 'shopify', externalId: 'gid://shopify/Location/1', name: 'Online')
    variant = { 'id' => 'gid://shopify/ProductVariant/7', 'title' => 'Tea', 'sku' => 'TEA-7', 'inventoryQuantity' => -3,
                'inventoryItem' => { 'id' => 'gid://shopify/InventoryItem/7', 'tracked' => true } }
    levels = { 'gid://shopify/InventoryItem/7' => [
      { 'location' => { 'id' => 'gid://shopify/Location/1' }, 'quantities' => [{ 'name' => 'available', 'quantity' => -3 }] }
    ] }
    ShopifyProduct.create!(id: 'gid://shopify/Product/7', title: 'Tea')
    ShopifyVariant.create!(id: variant['id'], productId: 'gid://shopify/Product/7', title: 'Tea', sku: 'TEA-7')

    CatalogSyncer.send(:sync_levels_batched!, [variant], levels, { 'gid://shopify/Location/1' => home }, home, Time.current)

    level = InventoryLevel.find_by!(source: 'shopify', shopifyVariantId: variant['id'])
    assert_equal 0, level.quantity, 'mirrored count stays clamped for the rest of the app'
    assert_equal(-3, level.sourceQuantity)
    assert_predicate level, :oversold?
    assert_equal [level.id], InventoryLevel.oversold.pluck(:id)
  end

  test 'sync_levels_batched! stores the variant total as raw when no location data exists' do
    home = Location.create!(source: 'shopify', externalId: 'gid://shopify/Location/1', name: 'Online')
    variant = { 'id' => 'gid://shopify/ProductVariant/8', 'title' => 'Tea', 'sku' => 'TEA-8', 'inventoryQuantity' => 4,
                'inventoryItem' => { 'id' => 'gid://shopify/InventoryItem/8', 'tracked' => false } }
    ShopifyProduct.create!(id: 'gid://shopify/Product/8', title: 'Tea')
    ShopifyVariant.create!(id: variant['id'], productId: 'gid://shopify/Product/8', title: 'Tea', sku: 'TEA-8')

    CatalogSyncer.send(:sync_levels_batched!, [variant], {}, {}, home, Time.current)

    level = InventoryLevel.find_by!(source: 'shopify', shopifyVariantId: variant['id'])
    assert_equal 4, level.sourceQuantity
    assert_not level.oversold?
  end
end
