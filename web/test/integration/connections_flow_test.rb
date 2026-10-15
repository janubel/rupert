# frozen_string_literal: true

require 'test_helper'

class ConnectionsFlowTest < ActionDispatch::IntegrationTest
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
    User.create!(email: 'conn@example.com', password: 'password123', role: 'admin', tenant_id: @tenant.id, name: 'Conn')
    post login_path, params: { email: 'conn@example.com', password: 'password123' }
    Current.tenant = @tenant
  end

  teardown do
    Current.tenant = nil
  end

  def get_page(path)
    get(path, params: { shop: 'm11u0i-sb.myshopify.com', embedded: '1', host: 'test-host' })
  end

  test 'connections page lists every service with status' do
    get_page connections_path
    assert_response :success
    assert_select 'h1', /Connections/
    assert_select 'h2', /Shopify/
    assert_select 'h2', /Square/
    assert_select 'h2', text: /Google Drive backup/, count: 0
    assert_select 'h2', /Buzz agent/
    assert_select 'h2', /Sync schedule/

    # Nothing configured yet → every card shows Not configured and keys masked/missing
    assert_select 'span', /Not configured/
    assert_select 'p', /SHOPIFY_CLIENT_ID/
    assert_select 'p', /SQUARE_ACCESS_TOKEN/
    assert_select 'p', /not set/
  end

  test 'only the platform operator sees Drive keys and legacy tenant configuration is ignored' do
    drive = ConnectionsGuide::SERVICES.find { |service| service.key == 'google_drive' }
    drive.keys.each { |key| EnvStore.set(key, 'untrusted-tenant-value') }
    user = User.find_by!(email: 'conn@example.com')
    user.update!(role: 'super_admin')
    get_page connections_path
    assert_response :success
    card = css_select('section.card').find { |node| node.text.include?('Google Drive backup') }
    assert card
    assert_includes card.text, 'Not configured'
    refute_includes card.text, 'untr'
    drive.keys.each { |key| EnvStore.platform_set(key, 'approved-platform-value') }
    get_page connections_path
    assert_response :success
    card = css_select('section.card').find { |node| node.text.include?('Google Drive backup') }
    assert_includes card.text, 'Configured'
    assert_includes card.text, 'appr••••alue'
    assert_includes card.text, 'database'
    refute_includes card.text, 'untr'
  end

  test 'a configured service shows its status and key source' do
    EnvStore.set('SQUARE_APPLICATION_ID', 'sq0idp-example')
    EnvStore.set('SQUARE_ACCESS_TOKEN', 'EAAAsecretvalue123')
    EnvStore.set('SQUARE_ENVIRONMENT', 'production')
    EnvStore.set('SQUARE_LOCATION_ID', 'L4JQ')

    get_page connections_path
    assert_response :success

    card = css_select('section.card').find { |node| node.text.include?('Square') }
    assert card
    assert_includes card.text, 'Configured'
    assert_includes card.text, 'EAAA••••e123'
    assert_includes card.text, 'database'
    assert card.css("a[href*='developer.squareup.com']").present?
  end

  test 'partially configured services show as partially set up' do
    EnvStore.set('SHOPIFY_CLIENT_ID', 'abc123')
    EnvStore.set('SHOPIFY_SHOP_DOMAIN', 'test-store.myshopify.com')

    get_page connections_path
    assert_response :success

    card = css_select('section.card').find { |node| node.text.include?('Shopify') }
    assert card
    assert_includes card.text, 'Partially set up'
    assert_includes card.text, 'not set' # client secret missing
  end

  test 'a cashier cannot view connections' do
    User.create!(email: 'conn-cashier@example.com', password: 'password123', role: 'cashier', tenant_id: @tenant.id,
      name: 'Cashier')
    delete logout_path
    post login_path, params: { email: 'conn-cashier@example.com', password: 'password123' }

    get_page connections_path
    follow_redirect!
    assert_match(/don't have permission/, flash[:alert])
  end
end
