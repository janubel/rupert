# frozen_string_literal: true

require 'test_helper'

class InventoryLocationViewTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    Shop.create!(shopify_domain: 'm11u0i-sb.myshopify.com', shopify_token: 'test-token')
    EnvStore.set('SHOPIFY_CLIENT_ID', 'test-client-id')
    EnvStore.set('SHOPIFY_CLIENT_SECRET', 'test-client-secret')
    post login_path, params: { email: 'admin@example.com', password: 'password' }

    @product = ShopifyProduct.create!(id: 'gid://shopify/Product/1', title: 'Tea', status: 'ACTIVE',
      tenant_id: @tenant.id)
    @online = Location.create!(source: 'shopify', externalId: 'gid://shopify/Location/1', name: 'Online store',
      active: true, tenant_id: @tenant.id)
    @rig = Location.create!(source: 'shopify', externalId: 'gid://shopify/Location/2', name: 'Market rig',
      active: true, tenant_id: @tenant.id)
    @home = Location.create!(source: 'square', externalId: 'sq-home', name: 'Home shop', active: true,
      tenant_id: @tenant.id)

    @item = SquareItem.create!(id: 'si1', name: 'Tea Item', tenant_id: @tenant.id)
    @variation = SquareVariation.create!(id: 'sv1', itemId: @item.id, sku: 'TEA-50', name: 'Tea 50g',
      tenant_id: @tenant.id)

    @linked = ShopifyVariant.create!(productId: @product.id, title: 'Tea / 50g', sku: 'TEA-50',
      inventoryQuantity: 7, tracked: true, tenant_id: @tenant.id)
    SkuLink.create!(sku: 'TEA-50', shopifyVariantId: @linked.id, squareVariationId: @variation.id,
      tenant_id: @tenant.id)
    InventoryLevel.create!(source: 'shopify', locationId: @online.id, shopifyVariantId: @linked.id, quantity: 5,
      available: 5, tenant_id: @tenant.id)
    InventoryLevel.create!(source: 'shopify', locationId: @rig.id, shopifyVariantId: @linked.id, quantity: 2,
      available: 2, tenant_id: @tenant.id)
    InventoryLevel.create!(source: 'square', locationId: @home.id, squareVariationId: @variation.id, quantity: 4,
      available: 4, tenant_id: @tenant.id)

    @unlinked = ShopifyVariant.create!(productId: @product.id, title: 'Tea / 100g', sku: 'TEA-100',
      inventoryQuantity: 3, tracked: true, tenant_id: @tenant.id)
    InventoryLevel.create!(source: 'shopify', locationId: @online.id, shopifyVariantId: @unlinked.id, quantity: 3,
      available: 3, tenant_id: @tenant.id)
  end

  teardown do
    Current.tenant = nil
  end

  def get_page(params: {})
    get inventory_index_path, params: params.merge(shop: 'm11u0i-sb.myshopify.com', embedded: '1', host: 'test-host')
  end

  test 'renders one stock column per active location plus totals and identity status' do
    get_page

    assert_response :success
    assert_select 'h1', 'Inventory'

    # A column header per location, labeled with its source.
    assert_select 'th', text: /Online store/
    assert_select 'th', text: /Market rig/
    assert_select 'th', text: /Home shop/

    # Per-location quantities for the linked variant.
    assert_select 'td', text: /^5$/
    assert_select 'td', text: /^2$/
    assert_select 'td', text: /^4$/

    # Identity chips, not a linked/unlinked binary.
    assert_select 'span.pill-fern', text: 'matched'
    assert_select 'span.pill-taupe', text: 'unlinked'
    assert_select 'td', text: /not carried/
  end

  test 'stock quantities stay correct when searches share a page number' do
    previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    coffee = ShopifyProduct.create!(id: 'gid://shopify/Product/2', title: 'Coffee', status: 'ACTIVE')
    variant = ShopifyVariant.create!(productId: coffee.id, title: 'Coffee / 50g', sku: 'COFFEE-50', tracked: true)
    InventoryLevel.create!(source: 'shopify', locationId: @online.id, shopifyVariantId: variant.id,
      quantity: 9, available: 9)

    get_page(params: { q: 'Tea' })
    assert_response :success
    get_page(params: { q: 'Coffee' })
    assert_response :success
    assert_select 'tbody tr', text: /COFFEE-50/ do
      assert_select 'td', text: /^9$/
    end

    get_page
    assert_select 'tbody tr', text: /COFFEE-50/ do
      assert_select 'td', text: /^9$/
    end
  ensure
    Rails.cache = previous_cache
  end

  test 'variant query count stays bounded across a page of products' do
    10.times do |number|
      product = ShopifyProduct.create!(id: "gid://shopify/Product/batch-#{number}", title: "Batch #{number}")
      ShopifyVariant.create!(productId: product.id, title: "Batch #{number}", sku: "BATCH-#{number}", tracked: true)
    end
    queries = []
    collector = lambda do |*args|
      payload = args.last
      queries << payload[:sql] if payload[:sql].match?(/SELECT .*FROM "ShopifyVariant"/) && !payload[:cached]
    end
    ActiveSupport::Notifications.subscribed(collector, 'sql.active_record') { get_page }

    assert_response :success
    assert_operator queries.length, :<=, 3, 'variant loading must not add a query for each product'
  end

  test 'oversold Shopify variants are announced without changing the shown stock' do
    get_page
    assert_response :success
    assert_select 'p[role=status]', text: /oversold/, count: 0

    InventoryLevel.where(source: 'shopify', shopifyVariantId: @linked.id).update_all(sourceQuantity: -4)
    get_page
    assert_response :success
    assert_select 'p[role=status]', text: /1\s+Shopify variant is oversold/
    assert_select 'td', text: /^5$/
  end
end
