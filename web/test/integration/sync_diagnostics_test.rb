# frozen_string_literal: true

require 'test_helper'

class SyncDiagnosticsTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @user = users(:regular_user)
    post login_path, params: { email: @user.email, password: 'password' }
    Current.user = @user
  end
  teardown { Current.reset }

  test 'hub shows safe diagnostics without credentials jobs configuration writes or raw failure text' do
    EnvStore.set('SQUARE_ACCESS_TOKEN', 'synthetic-never-display-token')
    SyncObservability.observe('shopify', 'catalog') { raise 'synthetic-never-display-token vendor-private-payload' } rescue nil
    settings = Setting.order(:id).map(&:attributes_before_type_cast)
    connections = PosConnection.order(:id).map(&:attributes_before_type_cast)
    attempts = SyncAttempt.count
    assert_no_enqueued_jobs { get connections_path }
    assert_response :success
    assert_equal 'no-store', response.headers['Cache-Control']
    assert_select '[data-sync-operation=catalog]', minimum: 1
    assert_select '[role=alert]', text: /Cause not recorded precisely/
    assert_includes response.body, 'Last successful acquisition'
    assert_includes response.body, 'Source event coverage watermark'
    refute_includes response.body, 'synthetic-never-display-token'
    refute_includes response.body, 'vendor-private-payload'
    assert_equal settings, Setting.order(:id).map(&:attributes_before_type_cast)
    assert_equal connections, PosConnection.order(:id).map(&:attributes_before_type_cast)
    assert_equal attempts, SyncAttempt.count
  end

  test 'platform backup references are restricted to a freshly authorized operator' do
    record = SyncAttempt.unscoped.create!(source: 'google_backup', operation: 'backup', status: 'failed',
      error_category: 'worker', queued_at: 1.minute.ago, started_at: 1.minute.ago, finished_at: Time.current)
    get connections_path
    refute_includes response.body, "SYNC-#{record.id}"
    @user.update!(role: 'super_admin')
    get connections_path
    assert_response :success
    assert_select '[data-connection-source=google_backup]'
    assert_includes response.body, "SYNC-#{record.id}"
    @user.update!(role: 'admin')
    get connections_path
    refute_includes response.body, "SYNC-#{record.id}"
  end
end
