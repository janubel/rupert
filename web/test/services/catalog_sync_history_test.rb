# frozen_string_literal: true

require 'test_helper'

class CatalogSyncHistoryTest < ActiveSupport::TestCase
  setup do
    travel_to Time.current.change(usec: 0)
    Current.user = users(:regular_user)
  end
  teardown do
    travel_back
    Current.reset
  end

  def historical_run(source, status: 'success', at: 5.minutes.ago)
    SyncRun.create!(source: source, status: status, mode: 'scheduled', actor: 'test', startedAt: at - 1.minute, finishedAt: at)
  end

  test 'combined success establishes Shopify evidence but not a possibly skipped Square read' do
    combined = historical_run('all')
    assert_equal combined.finishedAt, CatalogSyncHistory.legacy_success('shopify')
    assert_nil CatalogSyncHistory.legacy_success('square')
    square = historical_run('square', at: 20.minutes.ago)
    assert_equal square.finishedAt, CatalogSyncHistory.legacy_success('square')
  end

  test 'per-source watermark survives a combined run that failed after that source imported' do
    historical_run('all', status: 'failed')
    time = 10.minutes.ago.change(usec: 0)
    Setting.create!(key: 'sync_watermark_shopify', value: time.iso8601, tenant_id: Current.tenant_id)
    assert_equal time, CatalogSyncHistory.legacy_success('shopify')
    assert_nil CatalogSyncHistory.legacy_success('square')
  end

  test 'malformed and future watermarks cannot invent fresh evidence or break source cards' do
    %w[not-a-time tomorrow 2026-02-30T00:00:00Z].each do |value|
      setting = Setting.find_or_initialize_by(key: 'sync_watermark_shopify', tenant_id: Current.tenant_id)
      setting.update!(value: value)
      assert_nil CatalogSyncHistory.watermark('shopify')
      assert_nil CatalogSyncHistory.legacy_success('shopify')
      assert SourceSyncStatus.all(include_platform: false).find { |source| source[:key] == 'shopify' }
    end
    Setting.find_by!(key: 'sync_watermark_shopify').update!(value: 2.hours.from_now.iso8601)
    assert_nil CatalogSyncHistory.watermark('shopify')
    assert_nil CatalogSyncHistory.legacy_success('shopify')
  end

  test 'successful legacy records and watermarks stay tenant scoped' do
    historical_run('all')
    Setting.create!(key: 'sync_watermark_shopify', value: 1.minute.ago.iso8601, tenant_id: Current.tenant_id)
    Current.tenant = Tenant.create!(name: 'Other history', subdomain: 'other-history', status: 'active')
    assert_nil CatalogSyncHistory.legacy_success('shopify')
    assert_nil CatalogSyncHistory.watermark('shopify')
  end

  test 'an unrelated combined failure cannot invent a failed Square read' do
    EnvStore.stubs(:fetch).returns('synthetic-present')
    historical_run('all', status: 'failed')
    sources = SourceSyncStatus.all(include_platform: false)
    assert_equal 'Error', sources.find { |source| source[:key] == 'shopify' }[:badge]
    square = sources.find { |source| source[:key] == 'square' }
    assert_equal 'Awaiting pull', square[:badge]
    refute_equal 'Legacy failure · cause unknown', SourceHealth.for(square).first[:state]
    historical_run('square', status: 'failed', at: 1.minute.ago)
    assert_equal 'Error', SourceSyncStatus.all(include_platform: false).find { |source| source[:key] == 'square' }[:badge]
  end

  test 'malformed Square acquisition timestamps leave both source cards readable' do
    EnvStore.stubs(:fetch).returns('synthetic-present')
    Setting.create!(key: 'sync_watermark_square', value: 'not-a-time', tenant_id: Current.tenant_id)
    square = SourceSyncStatus.all(include_platform: false).find { |source| source[:key] == 'square' }
    assert_nil square[:last_at]
    assert_equal 'Awaiting pull', square[:badge]
  end
end
