# frozen_string_literal: true

require 'test_helper'

class SourceSyncsTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @tenant = tenants(:default_tenant)
    post login_path, params: { email: users(:regular_user).email, password: 'password' }
  end

  teardown { Current.reset }

  test 'dashboard and live refresh show seven honest source badges' do
    OnboardingController.stubs(:configured?).returns(true)
    get root_path
    assert_response :success
    assert_select '#source-sync-status [data-source]', count: 7
    assert_select '[data-source=shopify]', text: /Shopify.*Every 15 minutes/m
    assert_select '[data-source=bank]', text: /NAB \/ IRIS/
    assert_select '[data-source=google_backup]', text: /Every 6 hours/
    assert_select '[data-source=swipesimple]', text: /Needs login/
    assert_select '[data-source=authorize_net]', text: /Portal sign-in/
    get '/live/sync_status', params: { source_status: '1' }
    assert_response :success
    assert_includes response.body, 'source-sync-status'
    refute_includes response.body, 'transaction_key'
  end

  test 'Shopify card shows its successful source read even if a later adapter failed' do
    Current.tenant = @tenant
    { 'SHOPIFY_CLIENT_ID' => 'fixture-client', 'SHOPIFY_CLIENT_SECRET' => 'private-fixture-secret',
      'SHOPIFY_SHOP_DOMAIN' => 'fixture.myshopify.com' }.each { |key, value| EnvStore.set(key, value) }
    started = 2.minutes.ago.change(usec: 123_456)
    SyncRun.create!(source: 'all', mode: 'scheduled', status: 'failed', startedAt: started, finishedAt: started + 10.seconds)
    Setting.create!(key: 'sync_watermark_shopify', tenant_id: @tenant.id, value: started.iso8601)
    OnboardingController.stubs(:configured?).returns(true)
    get root_path
    assert_response :success
    assert_select '[data-source=shopify]', text: /Live/
    assert_select '[data-source=shopify] form[action=?]', source_syncs_path(source: 'shopify')
    refute_includes response.body, 'private-fixture-secret'
    get '/live/sync_status', params: { source_status: '1' }
    assert_response :success
    assert_includes response.body, 'data-source="shopify"'
    assert_includes response.body, 'Every 15 minutes'
  end

  test 'Square shows a successful pull separately from an older stored sale' do
    Current.tenant = @tenant
    EnvStore.set('SQUARE_ACCESS_TOKEN', 'private-square-fixture')
    Setting.create!(key: 'sync_watermark_square', tenant_id: @tenant.id, value: 2.minutes.ago.iso8601)
    order = Core::Order.new(source: 'square', source_order_id: 'old-square-sale',
      occurred_at: 20.days.ago, gross_cents: 1000, currency: 'USD')
    order[:status] = 'paid'
    order.save!
    OnboardingController.stubs(:configured?).returns(true)
    get root_path
    assert_response :success
    assert_select '[data-source=square]', text: /Live.*Last successful pull:.*Latest stored sale:/m
    assert_select '[data-source=square] form[action=?]', source_syncs_path(source: 'square')
    assert_select '[data-sales-source=square]', text: /No sales imported for today/
    refute_includes response.body, 'private-square-fixture'
  end

  test 'sales readers see source timestamps without settings or source write controls' do
    Current.tenant = @tenant
    users(:regular_user).update_permission_overrides!(%w[dashboard.read sales.read])
    Setting.create!(key: 'sync_watermark_shopify', tenant_id: @tenant.id, value: Time.current.iso8601)
    OnboardingController.stubs(:configured?).returns(true)
    get root_path
    assert_response :success
    assert_select '[data-sales-source=shopify] time[datetime]'
    assert_select '#source-sync-status', count: 0
    assert_select 'nav[aria-label="Daily work"] a[href=?]', ctrax_days_path
    assert_select 'nav[aria-label="Daily work"] a[href=?]', ctrax_pos_path, count: 0
  end

  test 'dashboard refresh updates sales in place and respects delegated widget permissions' do
    Current.tenant = @tenant
    users(:regular_user).update_permission_overrides!(%w[dashboard.read sales.read sync.read])
    get '/live/sync_status', params: { source_status: '1', dashboard: '1' }
    assert_response :success
    assert_includes response.body, 'target="dashboard-widget-today_channels"'
    assert_includes response.body, 'data-sales-source="ctrax"'
    refute_includes response.body, 'Website products'
    users(:regular_user).update_permission_overrides!(%w[sync.read])
    get '/live/sync_status', params: { dashboard: '1' }
    assert_response :success
    refute_includes response.body, 'dashboard-widget-'
  end

  test 'Shopify card action uses the existing tenant-scoped read sync' do
    assert_enqueued_with(job: SyncJob, args: [{ tenant_id: @tenant.id, mode: 'manual', source: 'shopify', actor: users(:regular_user).email }]) do
      post source_syncs_path, params: { source: 'shopify' }
    end
    assert_redirected_to syncs_path
  end

  test 'manual C-Trax sync works with its schedule paused and contains no credentials in queue' do
    Current.tenant = @tenant
    connection = PosConnection.create!(provider: 'ctrax', vendor_approved: true, hourly_sync_enabled: false,
      credentials_json: { api_url: 'https://fixture.api.cannatrax.net', api_username: 'fixture', api_password: 'private-password' }.to_json)
    assert_enqueued_with(job: CtraxStockSyncJob, args: [connection.id, { manual: true }]) do
      post source_sync_path('ctrax')
    end
    assert_redirected_to root_path
    refute_includes enqueued_jobs.inspect, 'private-password'
  end

  test 'SwipeSimple on demand opens login setup when credentials are absent' do
    previous = ENV.delete('RUPERT_SWIPESIMPLE_INBOX')
    assert_no_enqueued_jobs { post source_sync_path('swipesimple') }
    assert_redirected_to pos_connection_path('swipesimple')
  ensure
    ENV['RUPERT_SWIPESIMPLE_INBOX'] = previous
  end

  test 'SwipeSimple on demand uses website credentials even with an inbox and paused schedule' do
    Current.tenant = @tenant
    connection = PosConnection.create!(provider: 'swipesimple', environment: 'production', account_reference: '42',
      vendor_approved: true, reporting_enabled: false, credentials_json: { web_email: 'read@example.invalid', web_password: 'private-web-login' }.to_json)
    previous = ENV['RUPERT_SWIPESIMPLE_INBOX']
    ENV['RUPERT_SWIPESIMPLE_INBOX'] = '/private-inbox'
    assert_enqueued_with(job: SwipesimpleWebSyncJob, args: [connection.id, { manual: true }]) { post source_sync_path('swipesimple') }
    assert_redirected_to root_path
    refute_includes enqueued_jobs.inspect, 'private-web-login'
    assert_equal @tenant.id, connection.tenant_id
  ensure
    ENV['RUPERT_SWIPESIMPLE_INBOX'] = previous
  end

  test 'Authorize.net without API credentials uses portal imports without queuing API access' do
    assert_no_enqueued_jobs { post source_sync_path('authorize_net') }
    assert_redirected_to authorize_net_portal_exports_path
    get authorize_net_portal_exports_path
    assert_response :success
    assert_includes response.body, 'Expanded Fields/Comma Separated'
  end

  test 'readers cannot trigger any source sync or upload portal evidence' do
    reader = User.create!(email: 'source-reader@example.invalid', password: 'password123', role: 'reader', tenant: @tenant)
    delete logout_path
    post login_path, params: { email: reader.email, password: 'password123' }
    assert_no_enqueued_jobs do
      post source_sync_path('ctrax')
      assert_response :redirect
      post source_sync_path('swipesimple')
      assert_response :redirect
      post authorize_net_portal_exports_path
      assert_response :redirect
    end
  end
end
