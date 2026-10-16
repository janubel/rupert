# frozen_string_literal: true

require 'test_helper'

class SourceHealthTest < ActiveSupport::TestCase
  setup do
    travel_to Time.current.change(usec: 0)
    Current.user = users(:regular_user)
    %w[SHOPIFY_CLIENT_ID SHOPIFY_CLIENT_SECRET SHOPIFY_SHOP_DOMAIN].each { |key| EnvStore.set(key, 'synthetic-present') }
    SyncQueueHealth.stubs(:worker).returns(state: 'Recent worker heartbeat', last_at: Time.current)
    SyncQueueHealth.stubs(:execution).returns(state: 'No retained queue receipt', retry_at: nil)
  end
  teardown do
    travel_back
    Current.reset
  end

  def receipt(status, time:, operation: 'catalog', source: 'shopify', category: nil, finished: time)
    SyncAttempt.create!(source: source, operation: operation, status: status,
      error_category: category, queued_at: time, started_at: time, finished_at: finished)
  end

  def health(source: 'shopify', badge: 'Live')
    SourceHealth.for(key: source, badge: badge, ready: true, last_at: 1.day.ago).first
  end

  test 'older failure finishing late cannot override a newer successful acquisition' do
    receipt('failed', time: 30.minutes.ago, category: 'credentials', finished: Time.current)
    newer = receipt('succeeded', time: 1.minute.ago)
    state = health(badge: 'Error')
    assert_equal 'Current acquisition', state[:state]
    assert_equal newer.finished_at, state[:last_success_at]
    assert_nil state[:category]
    assert_equal 'Recovered', state.dig(:transition, :label)
    assert_equal 1.day.ago.to_i, state[:source_at].to_i
    assert_nil state[:source_event_at]
  end

  test 'fresh failure has a precise safe repair without erasing last success' do
    old = receipt('succeeded', time: 20.minutes.ago)
    failure = receipt('failed', time: 1.minute.ago, category: 'entitlement')
    state = health
    assert_equal 'Failed', state[:state]
    assert_equal old.finished_at, state[:last_success_at]
    assert_equal "SYNC-#{failure.id}", state[:reference]
    assert_includes state[:action], 'vendor'
    assert state[:alert]
  end

  test 'unchanged failures do not invent repeated recovery transitions' do
    receipt('failed', time: 2.minutes.ago, category: 'network')
    receipt('failed', time: 1.minute.ago, category: 'network')
    assert_nil health[:transition]
  end

  test 'stale acquisition shows alert and does not diagnose bad credentials' do
    receipt('succeeded', time: 2.hours.ago)
    state = health
    assert_equal 'Stale', state[:state]
    assert_nil state[:category]
    assert_includes state[:action], 'Do not change credentials'
  end

  test 'missing legacy failure reasons and attempt times stay unknown' do
    state = health(badge: 'Error')
    assert_equal 'Legacy failure · cause unknown', state[:state]
    assert_nil state[:last_attempt_at]
    assert_equal 'unknown', state[:category]
  end

  test 'queue retry is shown only from an actual queue receipt' do
    receipt('queued', time: 1.hour.ago)
    assert_equal 'Queue delayed', health[:state]
    retry_at = 10.minutes.from_now
    SyncQueueHealth.stubs(:execution).returns(state: 'Scheduled', retry_at: retry_at)
    assert_equal 'Queued', health[:state]
    assert_equal retry_at, health.dig(:queue, :retry_at)
    SyncQueueHealth.stubs(:execution).returns(state: 'Failed in worker', retry_at: nil)
    assert_equal 'worker', health[:category]
  end

  test 'stock success cannot hide a separate sales failure or paused sales schedule' do
    receipt('succeeded', time: 1.minute.ago, source: 'ctrax', operation: 'stock')
    receipt('failed', time: 2.minutes.ago, source: 'ctrax', operation: 'sales', category: 'data_contract')
    Ctrax::Client.stubs(:valid_credentials?).returns(true)
    PosConnection.create!(provider: 'ctrax', environment: 'production', vendor_approved: true,
      hourly_sync_enabled: true, credentials_json: { api_url: 'https://example.api.cannatrax.net', api_username: 'synthetic', api_password: 'synthetic' }.to_json)
    states = SourceHealth.for(key: 'ctrax', ready: true)
    assert_equal 'Current acquisition', states.first[:state]
    assert_equal 'Failed', states.last[:state]
    refute states.last[:enabled]
  end

  test 'workspace and platform history remain isolated' do
    row = receipt('failed', time: 1.minute.ago, category: 'credentials')
    Current.tenant = Tenant.create!(name: 'Other', subdomain: 'other-diagnostics', status: 'active')
    assert_empty health[:history]
    refute_includes health.to_json, "SYNC-#{row.id}"
    assert_empty SourceHealth.for(key: 'google_backup')
  end

  test 'partial processor acquisition is distinguished from full availability' do
    connection = PosConnection.new(provider: 'iris_reporting', environment: 'production', vendor_approved: true,
      reporting_enabled: true, reporting_auth_mode: 'api_key', account_reference: '123456',
      credentials_json: { api_url: 'https://example.iriscrm.com', api_token: 'synthetic-token' }.to_json,
      last_reported_at: Time.current, last_report_status: 'partial')
    PosConnection.stubs(:find_by).returns(connection)
    receipt('succeeded', time: 1.minute.ago, source: 'bank', operation: 'reporting')
    state = health(source: 'bank')
    assert_equal 'Partial acquisition', state[:state]
    assert_equal 'optional_reports', state[:category]
    assert state[:alert]
    assert_includes state[:action], 'do not mean zero'
  end

  test 'connector timestamps cannot hide a first instrumented failed attempt' do
    connection = PosConnection.new(provider: 'iris_reporting', environment: 'production', vendor_approved: true,
      reporting_enabled: true, reporting_auth_mode: 'api_key', account_reference: '123456',
      credentials_json: { api_url: 'https://example.iriscrm.com', api_token: 'synthetic-token' }.to_json,
      last_reported_at: Time.current, last_report_status: 'failed')
    PosConnection.stubs(:find_by).returns(connection)
    receipt('failed', time: 1.minute.ago, source: 'bank', operation: 'reporting', category: 'data_contract')
    state = health(source: 'bank')
    assert_equal 'Failed', state[:state]
    assert_equal 'data_contract', state[:category]
    assert_nil state[:last_success_at]
    assert_equal connection.last_reported_at, state[:legacy_at]
  end

  test 'one undecryptable source does not hide unrelated source health' do
    SourceSyncStatus.any_instance.stubs(:ctrax).raises(ActiveRecord::Encryption::Errors::Decryption.new('private-error'))
    sources = SourceSyncStatus.all(include_platform: false)
    ctrax = sources.find { |source| source[:key] == 'ctrax' }
    assert_equal 'Credentials unreadable', ctrax[:badge]
    assert_equal 5, sources.size
    assert sources.any? { |source| source[:key] == 'shopify' }
    refute_includes sources.to_json, 'private-error'
    state = SourceHealth.for(ctrax).first
    assert_equal 'encryption', state[:category]
    assert state[:alert]
    assert_includes state[:action], 'original encryption keys'
  end

  test 'missing reporting access is distinct from a deliberately paused configured connection' do
    state = health(source: 'authorize_net', badge: 'Portal snapshot')
    assert_equal 'Missing access', state[:state]
    assert_includes state.dig(:access, :missing_fields), 'Transaction Key'
    assert_includes state.dig(:access, :missing_fields), 'Gateway ID'
    assert_nil state[:category]
    assert_nil state[:last_attempt_at]
    assert state[:alert]
    connection = PosConnection.new(provider: 'authorize_net_reporting', vendor_approved: true,
      account_reference: '123456', credentials_json: { api_login_id: 'test-login', transaction_key: 'test-key' }.to_json)
    PosConnection.stubs(:find_by).returns(connection)
    state = health(source: 'authorize_net')
    assert_equal 'Automatic reads paused', state[:state]
    assert state.dig(:access, :ready)
    refute connection.reporting_enabled
  end

  test 'current missing access does not erase the result of an earlier failed read' do
    failure = receipt('failed', time: 1.minute.ago, source: 'square', category: 'credentials')
    EnvStore.stubs(:fetch).with('SQUARE_ACCESS_TOKEN', '').returns('')
    state = health(source: 'square')
    assert_equal 'Failed', state[:state]
    assert_equal 'credentials', state[:category]
    assert_equal "SYNC-#{failure.id}", state[:reference]
    assert_equal ['Access token'], state.dig(:access, :missing_fields)
  end

  test 'missing access after a successful read retains success but does not claim a schedule was paused' do
    success = receipt('succeeded', time: 1.minute.ago, source: 'square')
    EnvStore.stubs(:fetch).with('SQUARE_ACCESS_TOKEN', '').returns('')
    state = health(source: 'square')
    assert_equal 'Missing access', state[:state]
    assert_equal success.finished_at, state[:last_success_at]
    assert_nil state[:category]
    assert state[:alert]
  end

  test 'current combined Shopify success is legacy evidence without inventing a receipt' do
    SyncRun.create!(source: 'shopify', status: 'success', mode: 'manual', actor: 'test', startedAt: 3.hours.ago, finishedAt: 2.hours.ago)
    recent = SyncRun.create!(source: 'all', status: 'success', mode: 'scheduled', actor: 'test', startedAt: 5.minutes.ago, finishedAt: 4.minutes.ago)
    state = health
    assert_equal 'Awaiting observed success', state[:state]
    assert_equal recent.finishedAt, state[:legacy_at]
    assert_nil state[:last_success_at]
    assert_nil state[:last_attempt_at]
    assert_empty state[:history]
    refute state[:alert]
  end

  test 'recent legacy evidence cannot hide a new instrumented failure' do
    SyncRun.create!(source: 'all', status: 'success', mode: 'scheduled', actor: 'test', startedAt: 5.minutes.ago, finishedAt: 4.minutes.ago)
    receipt('failed', time: 1.minute.ago, category: 'entitlement')
    assert_equal 'Failed', health[:state]
    assert_equal 'entitlement', health[:category]
  end
end
