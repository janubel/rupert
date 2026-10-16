# frozen_string_literal: true

require 'test_helper'

class SourceHealthTest < ActiveSupport::TestCase
  setup do
    Current.user = users(:regular_user)
    SyncQueueHealth.stubs(:worker).returns(state: 'Recent worker heartbeat', last_at: Time.current)
    SyncQueueHealth.stubs(:execution).returns(state: 'No retained queue receipt', retry_at: nil)
  end
  teardown { Current.reset }

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
    connection = Struct.new(:reporting_enabled, :reporting_auth_mode, :last_reported_at, :last_report_status).new(true, 'api_key', Time.current, 'partial')
    PosConnection.stubs(:find_by).returns(connection)
    receipt('succeeded', time: 1.minute.ago, source: 'bank', operation: 'reporting')
    state = health(source: 'bank')
    assert_equal 'Partial acquisition', state[:state]
    assert_equal 'optional_reports', state[:category]
    assert state[:alert]
    assert_includes state[:action], 'do not mean zero'
  end

  test 'connector timestamps cannot hide a first instrumented failed attempt' do
    connection = Struct.new(:reporting_enabled, :reporting_auth_mode, :last_reported_at, :last_report_status).new(true, 'api_key', Time.current, 'failed')
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
    assert_equal 6, sources.size
    assert sources.any? { |source| source[:key] == 'shopify' }
    refute_includes sources.to_json, 'private-error'
    state = SourceHealth.for(ctrax).first
    assert_equal 'encryption', state[:category]
    assert state[:alert]
    assert_includes state[:action], 'original encryption keys'
  end
end
