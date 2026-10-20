# frozen_string_literal: true

require 'test_helper'

class AlertsRestockViewTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    Shop.create!(shopify_domain: 'm11u0i-sb.myshopify.com', shopify_token: 'test-token')
    EnvStore.set('SHOPIFY_CLIENT_ID', 'test-client-id')
    EnvStore.set('SHOPIFY_CLIENT_SECRET', 'test-client-secret')
    post login_path, params: { email: 'admin@example.com', password: 'password' }

    @product = ShopifyProduct.create!(id: 'gid://shopify/Product/1', title: 'Tea', status: 'ACTIVE',
      tenant_id: @tenant.id)
    @variant = ShopifyVariant.create!(productId: @product.id, title: 'Tea / 50g', sku: 'TEA-50',
      inventoryQuantity: 2, tracked: true, tenant_id: @tenant.id)
    StockAlert.create!(sku: 'TEA-50', quantity: 2, threshold: 5, status: 'open', shopifyVariantId: @variant.id)
  end

  teardown { Current.tenant = nil }

  test 'alerts page renders restock decision columns' do
    get alerts_path(status: 'open'), params: { shop: 'm11u0i-sb.myshopify.com', embedded: '1', host: 'test-host' }

    assert_response :success
    assert_select 'th', text: /\ASuggested/
    assert_select 'th', text: /\ACover/
    assert_select 'td', text: /no sales/ # no orders in fixtures -> honest empty advice
  end
end
