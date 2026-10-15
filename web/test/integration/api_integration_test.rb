# frozen_string_literal: true

require 'test_helper'

class ApiIntegrationTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = tenants(:default_tenant)
    @owner = users(:regular_user)
    Current.tenant = @tenant
    product = ShopifyProduct.create!(id: 'api-product', title: 'Tea')
    @variant = ShopifyVariant.create!(id: 'api-variant', productId: product.id, sku: 'API-TEA', title: 'Tea 50g')
    @location = Location.create!(id: 'api-location', source: 'shopify', externalId: 'api-external', name: 'Tea warehouse')
    @level = InventoryLevel.create!(id: 'api-level', source: 'shopify', locationId: @location.id,
      shopifyVariantId: @variant.id, quantity: 12, available: 9)
    @other = Tenant.create!(name: 'Other API tenant', subdomain: 'other-api')
    @other_user = User.create!(tenant: @other, email: 'other-api@example.com', role: 'admin', password: 'password')
    Current.tenant = @other
    other_product = ShopifyProduct.create!(id: 'other-api-product', title: 'Private other product')
    ShopifyVariant.create!(id: 'other-api-variant', productId: other_product.id, sku: 'OTHER-PRIVATE', title: 'Other')
    other_location = Location.create!(id: 'other-api-location', source: 'shopify', externalId: 'other-external', name: 'Other warehouse')
    InventoryLevel.create!(id: 'other-api-level', source: 'shopify', locationId: other_location.id,
      shopifyVariantId: 'other-api-variant', quantity: 99, available: 99)
    Current.tenant = @tenant
  end

  teardown { Current.reset }

  test 'bearer API ignores browser login and host tenant and returns only the token tenant' do
    login
    get api_v1_inventory_path
    assert_response :unauthorized
    token, secret = issue
    host! 'other-api.example.com'
    get api_v1_catalog_path, headers: bearer(secret)
    assert_response :success
    assert_equal ['API-TEA'], response.parsed_body.fetch('data').map { |row| row.fetch('sku') }
    get api_v1_inventory_path, headers: bearer(secret)
    assert_response :success
    assert_equal [@level.id], response.parsed_body.fetch('data').map { |row| row.fetch('id') }
    assert_equal 12, response.parsed_body['data'].first['quantity']
    assert_equal 9, response.parsed_body['data'].first['available']
    assert_equal 'no-store', response.headers['Cache-Control']
    _, other_secret = ApiAccessToken.issue(attributes: { name: 'Other', scopes: ['inventory:read'] }, user: @other_user, tenant: @other)
    get api_v1_inventory_path, headers: bearer(other_secret)
    assert_response :success
    assert_equal ['other-api-level'], response.parsed_body['data'].map { |row| row['id'] }
    get api_v1_inventory_path, headers: bearer(secret)
    assert_response :success
    assert_equal [@level.id], response.parsed_body['data'].map { |row| row['id'] }
    assert token.persisted?
  end

  test 'scopes and current owner permissions gate every request' do
    _, secret = issue(scopes: ['roadmap:read'])
    get api_v1_catalog_path, headers: bearer(secret)
    assert_response :forbidden
    get api_v1_roadmap_path, headers: bearer(secret)
    assert_response :success
    assert response.parsed_body['data']['features'].any?

    token, inventory_secret = issue
    @owner.update_permission_overrides!(['dashboard.read'])
    get api_v1_inventory_path, headers: bearer(inventory_secret)
    assert_response :forbidden
    token.update!(revoked_at: Time.current)
    get api_v1_inventory_path, headers: bearer(inventory_secret)
    assert_response :unauthorized
  end

  test 'expired revoked and disabled-owner tokens cannot authenticate' do
    token, secret = issue
    token.update!(revoked_at: Time.current)
    get api_v1_inventory_path, headers: bearer(secret)
    assert_response :unauthorized
    token, secret = issue
    ApiAccessToken.unscoped.where(id: token.id).update_all(expires_at: 1.minute.ago)
    get api_v1_inventory_path, headers: bearer(secret)
    assert_response :unauthorized
    _, secret = issue
    @owner.update!(active: false)
    get api_v1_inventory_path, headers: bearer(secret)
    assert_response :unauthorized
  end

  test 'catalog source and pagination are bounded with stable next pages' do
    Current.tenant = @tenant
    ShopifyVariant.create!(id: 'api-variant-2', productId: 'api-product', sku: 'API-SECOND', title: 'Second')
    square_item = SquareItem.create!(id: 'api-square-item', name: 'Square item')
    SquareVariation.create!(id: 'api-square-variation', itemId: square_item.id, name: 'Square size', sku: 'API-SQUARE')
    _, secret = issue
    get api_v1_catalog_path, params: { per_page: 1 }, headers: bearer(secret)
    assert_response :success
    assert_equal 1, response.parsed_body['data'].size
    assert_equal 2, response.parsed_body['meta']['next_page']
    first_id = response.parsed_body['data'].first['id']
    get api_v1_catalog_path, params: { page: 2, per_page: 1 }, headers: bearer(secret)
    assert_response :success
    assert_not_equal first_id, response.parsed_body['data'].first['id']
    assert_nil response.parsed_body['meta']['next_page']
    get api_v1_catalog_path, params: { source: 'square' }, headers: bearer(secret)
    assert_response :success
    assert_equal ['API-SQUARE'], response.parsed_body['data'].map { |row| row['sku'] }
    [{ per_page: 101 }, { page: 0 }, { page: 1001 }, { page: '1.5' }, { source: 'all' }].each do |parameters|
      get api_v1_catalog_path, params: parameters, headers: bearer(secret)
      assert_response :bad_request
    end
    get api_v1_inventory_path, params: { location_id: 'other-api-location' }, headers: bearer(secret)
    assert_response :success
    assert_empty response.parsed_body['data']
  end

  test 'token management stores only hashes and exposes a new secret once' do
    login
    post api_access_tokens_path, params: { api_access_token: { name: 'Reporting', scopes: ['inventory:read'] } }
    assert_response :created
    secret = css_select('textarea[name="issued_token"]').first.text
    assert_match ApiAccessToken::TOKEN_FORMAT, secret
    token = ApiAccessToken.unscoped.find_by!(name: 'Reporting')
    assert_equal Digest::SHA256.hexdigest(secret), token.token_digest
    assert_not_includes token.attributes.values.join, secret
    assert_equal 'no-store', response.headers['Cache-Control']
    assert_select 'meta[name="turbo-cache-control"][content="no-cache"]'
    get api_access_tokens_path
    assert_response :success
    assert_not_includes response.body, secret
    post revoke_api_access_token_path(token)
    assert_redirected_to api_access_tokens_path
    get api_v1_inventory_path, headers: bearer(secret)
    assert_response :unauthorized
  end

  test 'invalid scopes and unauthorized managers cannot issue or revoke tokens' do
    login
    [['inventory:write'], [], ['inventory:read', 'inventory:read']].each do |scopes|
      assert_no_difference -> { ApiAccessToken.unscoped.count } do
        post api_access_tokens_path, params: { api_access_token: { name: 'Invalid', scopes: scopes } }
        assert_response :unprocessable_entity
      end
    end
    other_token, = ApiAccessToken.issue(attributes: { name: 'Other', scopes: ['roadmap:read'] }, user: @other_user, tenant: @other)
    post revoke_api_access_token_path(other_token)
    assert_response :not_found
    assert_nil other_token.reload.revoked_at

    assert_no_difference -> { ApiAccessToken.unscoped.count } do
      post api_access_tokens_path, params: { api_access_token: { name: 'Bad expiry', scopes: ['roadmap:read'], expires_at: 'invalid' } }
      assert_response :unprocessable_entity
    end
    @owner.update_permission_overrides!(['settings.write'])
    assert_no_difference -> { ApiAccessToken.unscoped.count } do
      post api_access_tokens_path, params: { api_access_token: { name: 'No inventory permission', scopes: ['inventory:read'] } }
      assert_response :unprocessable_entity
    end
    @owner.update_permission_overrides!([])

    @owner.update!(role: 'reader')
    get api_access_tokens_path
    assert_response :redirect
    assert_no_difference -> { ApiAccessToken.unscoped.count } do
      post api_access_tokens_path, params: { api_access_token: { name: 'Denied', scopes: ['roadmap:read'] } }
      assert_response :redirect
    end
  end

  test 'deleting token owner removes tokens and invalidates their bearer secrets' do
    token, secret = ApiAccessToken.issue(attributes: { name: 'Deleted owner', scopes: ['roadmap:read'] }, user: @other_user, tenant: @other)
    assert token.persisted?
    Current.tenant = @other
    @other_user.destroy!
    assert_not ApiAccessToken.unscoped.exists?(id: token.id)
    get api_v1_roadmap_path, headers: bearer(secret)
    assert_response :unauthorized
  end

  private

  def login
    post login_path, params: { email: @owner.email, password: 'password' }
    assert_response :redirect
  end

  def issue(scopes: ApiAccessToken::SCOPES.keys)
    Current.tenant = @tenant
    token, secret = ApiAccessToken.issue(attributes: { name: 'Test integration', scopes: scopes }, user: @owner.reload, tenant: @tenant)
    assert token.persisted?, token.errors.full_messages.to_sentence
    [token, secret]
  end

  def bearer(secret)
    { 'Authorization' => "Bearer #{secret}" }
  end
end
