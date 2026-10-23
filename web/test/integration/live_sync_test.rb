# frozen_string_literal: true

require 'test_helper'

class LiveSyncTest < ActionDispatch::IntegrationTest
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
    EnvStore.set('SHOPIFY_CLIENT_ID', 'test-client-id')
    EnvStore.set('SHOPIFY_CLIENT_SECRET', 'test-client-secret')
    post login_path, params: { email: 'admin@example.com', password: 'password' }
  end

  teardown do
    Current.tenant = nil
    EnvStore.set('SHOPIFY_CLIENT_ID', nil)
    EnvStore.set('SHOPIFY_CLIENT_SECRET', nil)
  end

  test 'sync_status returns turbo_stream replaces for the live targets' do
    get live_sync_status_path, headers: { 'Accept' => 'text/vnd.turbo-stream.html' }
    assert_response :success
    assert_equal 'text/vnd.turbo-stream.html', response.media_type
    %w[sync-banner statusbar-sync sync-runs].each do |target|
      assert_match(/<turbo-stream action="replace" target="#{target}">/, response.body)
    end
  end

  test 'sync page includes the live-sync controller and banner' do
    get syncs_path
    assert_response :success
    assert_select '[data-controller~=live-sync]'
    assert_select '#sync-banner'
    assert_select '#sync-runs'
    assert_select 'h2', 'Platform changes'
    assert_select 'form[action=?]', push_guard_approve_syncs_path, count: 0
    assert_not_includes response.body, 'Every outbound write'
  end

  test 'dashboard includes the live-sync controller, banner, and the status-bar sync item' do
    get root_path
    assert_response :success
    assert_select '[data-controller~=live-sync]'
    assert_select '#sync-banner'
    assert_select 'footer #statusbar-sync'
  end

  test 'sync_status is rejected without a session' do
    delete logout_path
    get live_sync_status_path, headers: { 'Accept' => 'text/vnd.turbo-stream.html' }
    assert_response :redirect
  end

  test 'a CSV import pill identifies its own source instead of implying all sources refreshed' do
    run = SyncRun.create!(mode: 'csv', source: 'swipesimple', status: 'success', actor: 'test',
      startedAt: 10.minutes.ago, finishedAt: 2.minutes.ago)
    get syncs_path
    assert_response :success
    assert_select '#statusbar-sync', text: /swipesimple.*csv.*success/m
    assert_select '#statusbar-sync time[datetime=?]', run.finishedAt.iso8601
  end
end
