# frozen_string_literal: true

require 'test_helper'

class SourceSyncsTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @tenant = tenants(:default_tenant)
    post login_path, params: { email: users(:regular_user).email, password: 'password' }
  end

  teardown { Current.reset }

  test 'dashboard and live refresh show three honest source badges' do
    OnboardingController.stubs(:configured?).returns(true)
    get root_path
    assert_response :success
    assert_select '#source-sync-status [data-source]', count: 3
    assert_select '[data-source=swipesimple]', text: /Needs feed/
    assert_select '[data-source=authorize_net]', text: /Portal sign-in/
    get '/live/sync_status', params: { source_status: '1' }
    assert_response :success
    assert_includes response.body, 'source-sync-status'
    refute_includes response.body, 'transaction_key'
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

  test 'SwipeSimple on demand opens upload when there is no vendor feed' do
    previous = ENV.delete('RUPERT_SWIPESIMPLE_INBOX')
    assert_no_enqueued_jobs { post source_sync_path('swipesimple') }
    assert_redirected_to swipesimple_reports_path(anchor: 'import')
  ensure
    ENV['RUPERT_SWIPESIMPLE_INBOX'] = previous
  end

  test 'SwipeSimple delivery checks are restricted to the requesting tenant' do
    previous = ENV['RUPERT_SWIPESIMPLE_INBOX']
    ENV['RUPERT_SWIPESIMPLE_INBOX'] = '/private-inbox'
    assert_enqueued_with(job: SwipesimpleInboxJob, args: [{ tenant_id: @tenant.id }]) { post source_sync_path('swipesimple') }
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
