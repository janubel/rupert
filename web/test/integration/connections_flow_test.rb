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
    assert_select 'h1', 'Credentials & sync'
    assert_select 'h3', /Shopify/
    assert_select 'h3', /Square/
    assert_select '[data-credential-service=google_drive]', count: 0
    assert_select '[data-connection-source=google_backup]', count: 0
    assert_select 'h3', /Buzz agent/
    assert_select 'h2', /Sync improvement plan/

    # Nothing configured yet → every card shows Not configured and keys masked/missing
    assert_select 'span', /Not configured/
    assert_select 'li', /Client ID/
    assert_select 'li', /Access token/
    assert_select 'li', /not set/
    assert_equal 'no-store', response.headers['Cache-Control']
  end

  # Regression: Apple Pay and Google Pay were listed as services but had no
  # managed credential form, so their "Manage setup" links answered 404.
  test 'every setup link on the connections page leads to a page' do
    get_page connections_path
    assert_response :success

    links = css_select('a').select { |a| a.text.match?(/\A(Manage|View|Review|Open) setup\z/) }.map { |a| a['href'] }.uniq
    assert_operator links.size, :>=, 6, 'expected a setup link per service'

    links.each do |href|
      get_page href
      assert_response :success, "#{href} should render for a signed-in admin"
    end
  end

  test 'google pay has a managed credential form and apple pay points at the env import' do
    get_page edit_connection_path('google_pay')
    assert_response :success
    assert_select 'label', /Merchant name/
    assert_select 'label', /Merchant ID/

    get_page connections_path
    apple = css_select('[data-credential-service=apple_pay] a').find { |a| a.text.match?(/setup/) }
    assert apple, 'Apple Pay card should keep a setup link'
    assert_equal settings_path(anchor: 'env'), apple['href']
  end

  test 'only the platform operator sees Drive keys and legacy tenant configuration is ignored' do
    drive = ConnectionsGuide::SERVICES.find { |service| service.key == 'google_drive' }
    drive.keys.each { |key| EnvStore.set(key, 'untrusted-tenant-value') }
    user = User.find_by!(email: 'conn@example.com')
    user.update!(role: 'super_admin')
    get_page connections_path
    assert_response :success
    card = css_select('[data-credential-service=google_drive]').first
    assert card
    assert_includes card.text, 'Not configured'
    refute_includes card.text, 'untr'
    drive.keys.each { |key| EnvStore.platform_set(key, 'approved-platform-value') }
    get_page connections_path
    assert_response :success
    card = css_select('[data-credential-service=google_drive]').first
    assert_includes card.text, 'Configured'
    assert_includes card.text, 'Saved in Rupert'
    refute_includes response.body, 'approved-platform-value'
    refute_includes response.body, 'appr••••alue'
    refute_includes card.text, 'untr'
  end

  test 'a configured service shows its status and key source' do
    EnvStore.set('SQUARE_APPLICATION_ID', 'sq0idp-example')
    EnvStore.set('SQUARE_ACCESS_TOKEN', 'EAAAsecretvalue123')
    EnvStore.set('SQUARE_ENVIRONMENT', 'production')
    EnvStore.set('SQUARE_LOCATION_ID', 'L4JQ')

    get_page connections_path
    assert_response :success

    card = css_select('[data-credential-service]').find { |node| node.text.include?('Square') }
    assert card
    assert_includes card.text, 'Configured'
    refute_includes response.body, 'EAAAsecretvalue123'
    refute_includes response.body, 'EAAA••••e123'
    assert_includes card.text, 'Saved in Rupert'
    assert card.css("a[href*='developer.squareup.com']").present?
  end

  test 'partially configured services show as partially set up' do
    EnvStore.set('SHOPIFY_CLIENT_ID', 'abc123')
    EnvStore.set('SHOPIFY_SHOP_DOMAIN', 'test-store.myshopify.com')

    get_page connections_path
    assert_response :success

    card = css_select('[data-credential-service]').find { |node| node.text.include?('Shopify') }
    assert card
    assert_includes card.text, 'Partially set up'
    assert_includes card.text, 'not set' # client secret missing
    assert_select '[data-connection-source=shopify] [data-sync-access=missing]', text: /Missing: Client secret/
    assert_select '[data-credential-service=square] [data-sync-access=missing]', text: /Missing: Access token/
    assert_select '[data-connection-source=authorize_net] [data-sync-access=missing]', text: /Gateway ID/
    assert_select '[data-connection-source=authorize_net]', text: /Missing access/
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
