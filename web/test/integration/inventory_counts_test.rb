# frozen_string_literal: true

require 'test_helper'

class InventoryCountsTest < ActionDispatch::IntegrationTest
  setup do
    ShopifyAPI::Context.setup(
      api_key: 'test-key',
      api_secret_key: 'test-secret',
      api_version: ShopifyAPI::AdminVersions::SUPPORTED_ADMIN_VERSIONS.first,
      host_name: 'localhost',
      scope: 'read_products',
      is_private: false,
      is_embedded: false
    )
    Shop.create!(shopify_domain: 'm11u0i-sb.myshopify.com', shopify_token: 'test-token')
    Current.tenant = tenants(:default_tenant)
    @tenant = tenants(:default_tenant)
    EnvStore.set('SHOPIFY_CLIENT_ID', 'test-client-id')
    EnvStore.set('SHOPIFY_CLIENT_SECRET', 'test-client-secret')
    post login_path, params: { email: 'admin@example.com', password: 'password' }
  end

  teardown do
    Current.tenant = nil
    EnvStore.set('SHOPIFY_CLIENT_ID', nil)
    EnvStore.set('SHOPIFY_CLIENT_SECRET', nil)
  end

  test 'index lists counts' do
    get inventory_counts_path
    assert_response :success
    assert_select 'h1', /Manual counts/
  end

  test 'creating a count builds its items' do
    post inventory_counts_path, params: {
      inventory_count: { countedAt: Time.current.strftime('%Y-%m-%dT%H:%M'), note: 'stocktake' },
      items: [{ sku: 'A-1', quantity: '5' }, { sku: 'B-2', quantity: '3' }]
    }
    assert_redirected_to inventory_count_path(InventoryCount.last)

    count = InventoryCount.last
    assert count.draft?
    assert_equal 2, count.items.count
    assert_equal 8, count.total_quantity
    assert_equal 'admin@example.com', count.createdBy
  end

  test 'submit -> approve is record-only (no inventory change)' do
    @product = ShopifyProduct.create!(id: 'prod-1', title: 'Widget', tenant_id: @tenant.id)
    variant = ShopifyVariant.create!(
      title: 'Widget - Small',
      sku: 'WIDGET-S',
      productId: @product.id,
      tenant_id: @tenant.id
    )
    SkuLink.create!(sku: 'WIDGET-S', shopifyVariantId: variant.id, tenant_id: @tenant.id)
    location = Location.create!(
      source: 'shopify',
      externalId: 'loc-1',
      name: 'Main',
      tenant_id: @tenant.id
    )
    InventoryLevel.create!(
      source: 'shopify',
      locationId: location.id,
      shopifyVariantId: variant.id,
      quantity: 10,
      tenant_id: @tenant.id
    )

    post inventory_counts_path, params: {
      inventory_count: { countedAt: Time.current.strftime('%Y-%m-%dT%H:%M'), locationId: location.id },
      items: [{ sku: 'WIDGET-S', quantity: '7' }]
    }
    count = InventoryCount.last

    post submit_inventory_count_path(count)
    assert count.reload.pending?

    post approve_inventory_count_path(count)
    assert count.reload.approved?
    assert_equal 10, InventoryLevel.total_for_variant(variant.id)
    refute InventoryMovement.exists?(sku: 'WIDGET-S')
    assert count.appliedAt.present?
  end

  test 'reject sets the count to rejected' do
    count = InventoryCount.create!(countedAt: Time.current, tenant_id: @tenant.id)
    count.items.create!(sku: 'A-1', quantity: 2, tenant_id: @tenant.id)
    count.snapshot_previous!
    count.submit!

    post reject_inventory_count_path(count)
    assert count.reload.rejected?
  end

  test 'readers cannot create or approve counts' do
    reader = User.create!(
      email: 'reader@example.com',
      password: 'password123',
      role: 'reader',
      tenant: tenants(:default_tenant)
    )
    delete logout_path
    post login_path, params: { email: 'reader@example.com', password: 'password123' }
    assert_equal reader.id, session[:user_id]

    get inventory_counts_path
    assert_response :success

    post inventory_counts_path, params: {
      inventory_count: { countedAt: Time.current.strftime('%Y-%m-%dT%H:%M') },
      items: [{ sku: 'A-1', quantity: '5' }]
    }
    assert_redirected_to inventory_counts_path
    assert_match(/don't have permission/, flash[:alert])
    assert_equal 0, InventoryCount.count
  end

  test 'prepared sheet pre-fills the selected location mirror' do
    @product = ShopifyProduct.create!(id: 'prod-1', title: 'Widget', tenant_id: @tenant.id)
    variant = ShopifyVariant.create!(
      title: 'Widget - Small',
      sku: 'WIDGET-S',
      productId: @product.id,
      tenant_id: @tenant.id
    )
    SkuLink.create!(sku: 'WIDGET-S', shopifyVariantId: variant.id, tenant_id: @tenant.id)
    location = Location.create!(
      source: 'shopify',
      externalId: 'loc-1',
      name: 'Main',
      tenant_id: @tenant.id
    )
    InventoryLevel.create!(
      source: 'shopify',
      locationId: location.id,
      shopifyVariantId: variant.id,
      quantity: 10,
      tenant_id: @tenant.id
    )

    get new_inventory_count_path(location_id: location.id)
    assert_response :success
    assert_select 'table#count-table'
    assert_select "input[name='items[0][sku]'][value='WIDGET-S']"
    assert_select "input[name='items[0][quantity]'][value='10']"
    assert_select 'td', /Widget/
  end

  test 'prepared sheet requires a location and blank counts may be saved without comparisons' do
    get new_inventory_count_path
    assert_response :success
    assert_select 'select[name=location_id]'
    assert_select 'p', /Choose a location above/
    assert_select 'input[name="items[0][quantity]"]', count: 0
    post inventory_counts_path, params: {
      inventory_count: { countedAt: Time.current.strftime('%Y-%m-%dT%H:%M') },
      items: [{ sku: 'UNKNOWN-1', quantity: '3' }]
    }
    count = InventoryCount.last
    post submit_inventory_count_path(count)
    assert count.reload.pending?
    assert_nil count.items.first.previousQuantity
    assert_nil count.items.first.delta
    get inventory_count_path(count)
    assert_select 'p', /Choose a platform location to compare stock/
  end

  test 'prepared sheet can be toggled to a blank sheet' do
    get new_inventory_count_path(prepared: 0)
    assert_response :success
    assert_select 'table#count-table', count: 0
    assert_select "input[name='items[][sku]']"
  end

  test 'submitting the prepared sheet with overrides records them without applying' do
    @product = ShopifyProduct.create!(id: 'prod-2', title: 'Gummies', tenant_id: @tenant.id)
    variant = ShopifyVariant.create!(
      title: 'Gummies - Bottle',
      sku: 'GUM-1',
      productId: @product.id,
      tenant_id: @tenant.id
    )
    SkuLink.create!(sku: 'GUM-1', shopifyVariantId: variant.id, tenant_id: @tenant.id)
    location = Location.create!(
      source: 'shopify',
      externalId: 'loc-2',
      name: 'Main',
      tenant_id: @tenant.id
    )
    InventoryLevel.create!(
      source: 'shopify',
      locationId: location.id,
      shopifyVariantId: variant.id,
      quantity: 10,
      tenant_id: @tenant.id
    )

    post inventory_counts_path, params: {
      inventory_count: { countedAt: Time.current.strftime('%Y-%m-%dT%H:%M') },
      items: [
        { sku: 'GUM-1', quantity: '7' },
        { sku: 'OTHER', quantity: '0' }
      ]
    }
    count = InventoryCount.last
    assert_equal 2, count.items.count
    gum_item = count.items.find_by(sku: 'GUM-1')
    assert gum_item
    assert_equal 7, gum_item.quantity

    post submit_inventory_count_path(count)
    post approve_inventory_count_path(count)
    assert count.reload.approved?
    assert_equal 10, InventoryLevel.total_for_variant(variant.id)
    refute InventoryMovement.exists?(sku: 'GUM-1')
  end
end
