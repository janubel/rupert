# frozen_string_literal: true

require 'test_helper'

class InventoryPdfTest < ActionDispatch::IntegrationTest
  setup do
    Current.tenant = tenants(:default_tenant)
    post login_path, params: { email: 'admin@example.com', password: 'password' }

    ShopifyProduct.create!(id: 'p1', title: 'CBD', totalInventory: 3)
    @shopify_variant = ShopifyVariant.create!(
      title: 'Oil',
      sku: 'OIL-1',
      productId: 'p1',
      price: 25.0,
      inventoryQuantity: 3
    )

    @loc = Location.create!(source: 'square', externalId: 'loc1', name: 'Main Shop')
    SquareItem.create!(id: 'sqitem1', name: 'CBD')
    @square_variation = SquareVariation.create!(itemId: 'sqitem1', name: 'Oil', sku: 'OIL-1')

    SkuLink.create!(
      sku: 'OIL-1',
      shopifyVariantId: @shopify_variant.id,
      squareVariationId: @square_variation.id
    )
    InventoryLevel.create!(
      source: 'square',
      locationId: @loc.externalId,
      squareVariationId: @square_variation.id,
      quantity: 5
    )
    InventoryLevel.create!(
      source: 'shopify',
      locationId: 'shop-loc',
      shopifyVariantId: @shopify_variant.id,
      quantity: 3
    )
    SyncRun.create!(
      mode: 'scheduled',
      status: 'success',
      source: 'all',
      startedAt: 30.minutes.ago,
      finishedAt: 28.minutes.ago
    )
  end

  teardown do
    Current.tenant = nil
  end

  test 'the inventory page links to the PDF snapshot' do
    get inventory_index_path

    assert_response :success
    assert_select 'a[href=?]', pdf_inventory_index_path, text: 'Download snapshot PDF'
  end

  test 'downloads a PDF snapshot of the current inventory' do
    get pdf_inventory_index_path

    assert_response :success
    assert_equal 'application/pdf', response.media_type
    assert_includes response.headers['Content-Disposition'], 'attachment'
    assert_includes response.headers['Content-Disposition'], 'inventory-'
    assert response.body.start_with?('%PDF')
  end

  test 'operational inventory offers the shared stock CSV instead of the historical PDF' do
    get stock_comparison_path
    assert_response :success
    download_href = nil
    assert_select 'a', text: 'Download CSV' do |links|
      download_href = links.first['href']
    end
    get download_href
    assert_response :success
    assert_equal 'text/csv', response.media_type
    assert_includes response.headers['Content-Disposition'], 'shopify-ctrax-stock'
    assert_includes response.body, 'Shopify on hand'
  end

  test 'recommended skus CSV downloads the full Shopify vs Square SKU report' do
    ShopifyProduct.create!(id: 'p2', title: 'Other Product')
    ShopifyVariant.create!(title: 'Variant A', sku: 'SHARED-1', productId: 'p1', price: 1.0, inventoryQuantity: 5,
      tracked: true)
    ShopifyVariant.create!(title: 'Variant B', sku: 'SHARED-1', productId: 'p2', price: 2.0, inventoryQuantity: 3,
      tracked: true)

    get recommended_skus_inventory_index_path

    assert_response :success
    assert_equal 'text/csv', response.media_type
    assert_includes response.headers['Content-Disposition'], 'sku-report'
    assert_includes response.body, 'Shopify SKU'
    assert_includes response.body, 'Square SKU'
    assert_includes response.body, 'Status'
    assert_includes response.body, 'Proposed SKU'
    assert_includes response.body, 'SHARED-1'
    assert_includes response.body, 'duplicate-across-products'
    assert_includes response.body, 'SHARED-1-OP', 'non-primary product gets a unique suffix'
  end
end
