# frozen_string_literal: true

require 'test_helper'

class WarehouseFlowTest < ActionDispatch::IntegrationTest
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
    @user = User.create!(email: 'warehouse@example.com', password: 'password123', role: 'admin', tenant_id: @tenant.id)
    post login_path, params: { email: 'warehouse@example.com', password: 'password123' }
    Current.tenant = @tenant
  end

  teardown do
    Current.tenant = nil
  end

  def get_page(path)
    get(path, params: { shop: 'm11u0i-sb.myshopify.com', embedded: '1', host: 'test-host' })
  end

  test 'create a vendor link and manage it' do
    get_page warehouse_path
    assert_response :success

    post warehouse_shares_path, params: {
      name: 'GreenLeaf Distributors',
      priceMultiplier: '0.85',
      shop: 'm11u0i-sb.myshopify.com',
      embedded: '1'
    }
    follow_redirect!
    assert_response :success

    share = WarehouseShare.unscoped.find_by!(name: 'GreenLeaf Distributors')
    assert share.token.present?

    assert_select 'h1', /GreenLeaf Distributors/
    assert_select 'code', %r{/w/}
  end

  test 'vendor share admin page renders with tiers' do
    share = WarehouseShare.create!(name: 'Blue Oak', priceMultiplier: 0.9, tenant: @tenant)
    WarehouseTier.create!(shareId: share.id, minQty: 10, discountPercent: 5)

    get_page warehouse_share_path(share)
    assert_response :success
    assert_select 'h1', /Blue Oak/
    assert_select "input#name[value='Blue Oak']"
    assert_select "input#priceMultiplier[value='0.9']"
    assert_select 'input', value: '10'
  end

  test 'update vendor share settings and tiers' do
    share = WarehouseShare.create!(name: 'Blue Oak', priceMultiplier: 0.9, tenant: @tenant)
    tier = WarehouseTier.create!(shareId: share.id, minQty: 10, discountPercent: 5)

    patch warehouse_share_path(share), params: {
      name: 'Blue Oak North',
      priceMultiplier: '0.8',
      status: 'active',
      useCustomTiers: '1',
      shop: 'm11u0i-sb.myshopify.com',
      embedded: '1'
    }
    follow_redirect!
    assert_response :success
    share.reload
    assert_equal 'Blue Oak North', share.name
    assert_equal 0.8, share.priceMultiplier
    assert share.use_custom_tiers?

    post update_tiers_warehouse_share_path(share), params: {
      tiers: {
        tier.id.to_s => { id: tier.id, minQty: '10', discountPercent: '7' },
        'new' => { minQty: '25', discountPercent: '10' }
      },
      shop: 'm11u0i-sb.myshopify.com',
      embedded: '1'
    }
    follow_redirect!
    assert_response :success
    assert_equal 7, share.tiers.find(tier.id).discountPercent
    assert_equal 10, share.tiers.find_by!(minQty: 25).discountPercent
  end

  test 'public warehouse sale page renders tiered catalog' do
    share = WarehouseShare.create!(name: 'Red Barn', priceMultiplier: 0.85, useCustomTiers: true, tenant: @tenant)
    WarehouseTier.create!(shareId: share.id, minQty: 10, discountPercent: 5)
    product = ShopifyProduct.create!(id: 'prod-herbal', title: 'Herbal Tea', status: 'ACTIVE', tenant_id: @tenant.id)
    ShopifyVariant.create!(id: 'var-herbal', productId: product.id, title: '50g', price: 20.0, sku: 'TEA-50',
      tracked: true, tenant_id: @tenant.id)

    get warehouse_sale_path(share.token)
    assert_response :success
    assert_select 'h1', /Red Barn/
    assert_select 'article', /Herbal Tea/
    assert_select 'article', /50g/
    assert_select 'p', /available/
    assert_select 'span.pill-olive', /10\+ units/
  end

  test 'inactive or unknown warehouse sale token returns not found' do
    get warehouse_sale_path('nope-nope-nope')
    assert_response :not_found

    share = WarehouseShare.create!(name: 'Closed Shop', status: 'inactive', tenant: @tenant)
    get warehouse_sale_path(share.token)
    assert_response :not_found
  end

  test 'delete a vendor share' do
    share = WarehouseShare.create!(name: 'Gone Soon', tenant: @tenant)

    delete warehouse_share_path(share), params: { shop: 'm11u0i-sb.myshopify.com', embedded: '1' }
    assert_redirected_to warehouse_path
    follow_redirect!
    assert_response :success
    assert_nil WarehouseShare.find_by(token: share.token)
  end

  test 'public sale page lists only the share tenants default tiers' do
    other = Tenant.create!(name: 'Other Co', subdomain: "other#{SecureRandom.hex(4)}")
    Current.set(tenant: @tenant) { WarehouseTier.create!(shareId: nil, minQty: 10, discountPercent: 5) }
    Current.set(tenant: other) { WarehouseTier.create!(shareId: nil, minQty: 99, discountPercent: 50) }
    share = WarehouseShare.create!(name: 'Red Barn', priceMultiplier: 1, tenant: @tenant)

    get warehouse_sale_path(share.token)
    assert_response :success
    assert_select 'span.pill-olive', /10\+ units/
    assert_select 'span.pill-olive', text: /99\+ units/, count: 0
  end
end
