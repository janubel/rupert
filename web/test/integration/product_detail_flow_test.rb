# frozen_string_literal: true

require 'test_helper'

class ProductDetailFlowTest < ActionDispatch::IntegrationTest
  module TestShopifySession
    def current_shopify_session
      @test_session ||= ShopifyAPI::Auth::Session.new(
        shop: 'm11u0i-sb.myshopify.com',
        access_token: 'test-token',
        is_online: false,
        expires: Time.now + 3600
      )
    end
  end

  ShopifyApp::TokenExchange.prepend(TestShopifySession)

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

    @tenant = Tenant.create!(name: 'Test Co', subdomain: 'testco')
    @user = User.create!(email: 'inventory@example.com', password: 'password123', role: 'admin', tenant_id: @tenant.id)
    post login_path, params: { email: 'inventory@example.com', password: 'password123' }
    Current.tenant = @tenant

    @product = ShopifyProduct.create!(id: 'prod-detail', title: 'Herbal Tea', status: 'ACTIVE', tenant_id: @tenant.id)
    @variant = ShopifyVariant.create!(
      id: 'var-detail',
      productId: @product.id,
      title: '50g',
      sku: 'TEA-50',
      price: 20.0,
      inventoryQuantity: 8,
      tracked: true,
      tenant_id: @tenant.id
    )
    @square_item = SquareItem.create!(id: 'item-detail', name: 'Herbal Tea', tenant_id: @tenant.id)
    @square_variation = SquareVariation.create!(
      id: 'var-square', itemId: @square_item.id, name: 'Tea 50g', sku: 'TEA-50', tenant_id: @tenant.id
    )
  end

  teardown do
    Current.tenant = nil
  end

  def get_page(path)
    get(path, params: { shop: 'm11u0i-sb.myshopify.com', embedded: '1', host: 'test-host' })
  end

  test 'variant detail page renders quantities and link state' do
    get_page shopify_variant_path(@variant)
    assert_response :success
    assert_select 'h1', /Herbal Tea · 50g/
    assert_select '.item-hero-ids', /SKU TEA-50/
    assert_select 'h2', /Square link/
    assert_select 'h2', /Stock everywhere/
    assert_select 'span.pill-taupe', /Not linked/
  end

  test 'manually link a variant to a Square variation' do
    get_page shopify_variant_path(@variant)
    assert_response :success
    assert_select "select[name=square_variation_id] option[value='var-square']", text: /Tea 50g/

    post link_shopify_variant_path(@variant), params: {
      square_variation_id: @square_variation.id,
      shop: 'm11u0i-sb.myshopify.com',
      embedded: '1'
    }
    follow_redirect!
    assert_response :success

    link = SkuLink.find_by!(shopifyVariantId: @variant.id)
    assert_equal @square_variation.id, link.squareVariationId
    assert_equal 'manual', link.matchSource
    assert_select 'span.pill-fern', /Linked to Square/
    assert_select 'p', /Tea 50g/
  end

  test 'unlink breaks the link' do
    SkuLink.create!(tenant_id: @tenant.id, shopifyVariantId: @variant.id, squareVariationId: @square_variation.id,
      sku: 'TEA-50')

    post unlink_shopify_variant_path(@variant), params: { shop: 'm11u0i-sb.myshopify.com', embedded: '1' }
    follow_redirect!
    assert_response :success

    tombstone = SkuLink.find_by!(shopifyVariantId: @variant.id)
    assert_nil tombstone.squareVariationId
    assert_equal 'manual-unlink', tombstone.matchSource
    refute tombstone.auto
    SquareSyncer.send(:sync_links!, [{ variationId: @square_variation.id, sku: @variant.sku }])
    assert_nil tombstone.reload.squareVariationId
    assert_select 'span.pill-taupe', /Not linked/
  end

  test 'manual link takes precedence over another variants inferred Square claim' do
    other = ShopifyVariant.create!(id: 'automatic-claim-variant', productId: @variant.productId,
      title: 'Other inferred item', sku: @variant.sku)
    inferred = SkuLink.create!(shopifyVariantId: other.id, squareVariationId: @square_variation.id, sku: other.sku)
    post link_shopify_variant_path(@variant), params: { square_variation_id: @square_variation.id }
    assert_redirected_to shopify_variant_path(@variant)
    assert_equal @square_variation.id, SkuLink.find_by!(shopifyVariantId: @variant.id).squareVariationId
    assert_nil inferred.reload.squareVariationId
  end

  test 'stock comparison table links to variant detail' do
    @variant.product.update!(catalog_present: true)
    @variant.update!(catalog_present: true)
    get_page stock_comparison_path
    assert_response :success
    assert_select "a[href='#{shopify_variant_path(@variant)}']", text: /50g/
  end
end
