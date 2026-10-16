# frozen_string_literal: true

require 'test_helper'

class SyncEngineTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
  end

  teardown do
    travel_back
    SyncRun.delete_all
    Current.tenant = nil
  end

  test 'stale running syncs are failed before a new sync starts' do
    stale = SyncRun.create!(
      mode: 'scheduled',
      status: 'running',
      source: 'all',
      startedAt: (SyncEngine::STALE_RUN_AFTER + 1.minute).ago
    )

    SyncEngine.send(:recover_stale_runs!)

    stale.reload
    assert_predicate stale, :failed?
    assert_not_nil stale.finishedAt
    assert_includes stale.error, 'Automatically recovered stale sync'
  end

  test 'a recent running sync still blocks overlap' do
    SyncRun.create!(
      mode: 'scheduled',
      status: 'running',
      source: 'all',
      startedAt: 5.minutes.ago
    )

    assert_raises(SyncEngine::AlreadyRunning) do
      SyncEngine.send(:create_run!, mode: 'scheduled', source: 'all', actor: 'user')
    end
  end

  test 'run! proactively recovers an orphaned run so the schedule stays alive' do
    # A worker restart left an old run marked running (no details/error) —
    # run! must clear it before starting, not block for the whole window.
    orphan = SyncRun.create!(
      mode: 'scheduled',
      status: 'running',
      source: 'all',
      startedAt: (SyncEngine::STALE_RUN_AFTER + 1.minute).ago
    )

    ShopifyClient.stubs(:configured?).returns(true)
    CatalogSyncer.stubs(:sync!).returns({ products: 1, variants: 1, orders: { 'nodes' => [] } })
    LedgerImporter.stubs(:from_shopify_orders!).returns(nil)
    SquareClient.stubs(:configured?).returns(false)
    AlertGenerator.stubs(:sync!).returns({ created: 0, resolved: 0 })

    run = SyncEngine.run!(mode: 'scheduled', actor: 'scheduler')

    assert_predicate run, :success?
    assert_predicate orphan.reload, :failed?
    assert_equal 0, SyncRun.unscoped.where(status: 'running').count, 'only the new run exists, no orphans'
  end

  test 'a Square sync (read-only mirror) still runs while Square is frozen' do
    assert PlatformPushGuard.frozen?('square')

    SquareClient.stubs(:configured?).returns(true)
    SquareSyncer.stubs(:sync!).returns({ items: [], variations: [], levels: [], links: [], orders: [], locations: [] })
    LedgerImporter.stubs(:from_square_orders!).returns(nil)

    run = SyncEngine.run_source!('square', actor: 'user')

    assert_predicate run, :success?
    assert_equal 'square', run.source
  end

  test 'a frozen Square is reported but writes are gated only by explicit confirmation' do
    assert PlatformPushGuard.frozen?('square')
    assert_raises(PlatformPushGuard::UnconfirmedError) { PlatformPushGuard.authorize!('square', actor: 'user') }

    Current.confirm_push!
    assert PlatformPushGuard.authorize!('square', actor: 'user')
  end

  test 'Current.sync_run is set for the duration of a sync and reset after' do
    SquareClient.stubs(:configured?).returns(true)
    SquareSyncer.stubs(:sync!).returns({ items: [], variations: [], levels: [], links: [], orders: [], locations: [] })
    captured = nil
    LedgerImporter.stubs(:from_square_orders!).with do |_orders|
      captured = Current.sync_run_id
      true
    end.returns(nil)

    run = SyncEngine.run_source!('square', actor: 'user')

    assert_equal run.id, captured
    assert_nil Current.sync_run_id
  end

  test 'the scheduled sync is a read-only mirror — no reconcile plan, no quantity push' do
    ShopifyClient.stubs(:configured?).returns(true)
    CatalogSyncer.stubs(:sync!).returns({ products: 1, variants: 1, orders: { 'nodes' => [] } })
    LedgerImporter.stubs(:from_shopify_orders!).returns(nil)
    SquareClient.stubs(:configured?).returns(false)
    AlertGenerator.stubs(:sync!).returns({ created: 0, resolved: 0 })

    run = SyncEngine.run!(mode: 'scheduled', actor: 'scheduler')

    assert_predicate run, :success?
    details = JSON.parse(run.details)
    refute details.key?('reconcile'), 'no drift plan is computed or recorded'
    refute details.key?('maintain'), 'no lock-step quantity push runs'
  end

  test 'a successful sync advances the per-source order watermarks' do
    ShopifyClient.stubs(:configured?).returns(true)
    CatalogSyncer.stubs(:sync!).returns({ products: 1, variants: 1, orders: { 'nodes' => [] } })
    LedgerImporter.stubs(:from_shopify_orders!).returns(nil)
    SquareClient.stubs(:configured?).returns(true)
    SquareSyncer.stubs(:sync!).returns({ items: [], variations: [], levels: [], links: [], orders: [], locations: [] })
    LedgerImporter.stubs(:from_square_orders!).returns(nil)
    AlertGenerator.stubs(:sync!).returns({ created: 0, resolved: 0 })

    run = SyncEngine.run!(mode: 'scheduled', actor: 'scheduler')

    assert_predicate run, :success?
    shopify_wm = Time.zone.parse(Setting.find_by!(key: 'sync_watermark_shopify', tenant_id: Current.tenant_id).value)
    square_wm = Time.zone.parse(Setting.find_by!(key: 'sync_watermark_square', tenant_id: Current.tenant_id).value)
    assert_in_delta run.startedAt, shopify_wm, 1.second
    assert_in_delta run.startedAt, square_wm, 1.second
  end

  test 'incremental runs fetch only the watermark window plus refresh tail' do
    travel_to Time.zone.local(2026, 10, 16, 12)
    Setting.create!(key: 'sync_watermark_shopify', value: 2.hours.ago.iso8601, tenant_id: Current.tenant_id)

    captured_since = nil
    CatalogSyncer.stubs(:sync!).with do |args|
      captured_since = args[:since]
      true
    end
                 .returns({ products: 1, variants: 1, orders: { 'nodes' => [] } })
    LedgerImporter.stubs(:from_shopify_orders!).returns(nil)
    SquareClient.stubs(:configured?).returns(false)
    AlertGenerator.stubs(:sync!).returns({ created: 0, resolved: 0 })

    SyncEngine.run!(mode: 'scheduled', actor: 'scheduler')

    # since = watermark - 48h tail -> about 50 hours ago, not the 30-day default.
    assert_not_nil captured_since
    assert_operator Time.zone.parse(captured_since), :>, 3.days.ago
  end

  test 'explicit history_days bypasses the watermark (manual backfill)' do
    Setting.create!(key: 'sync_watermark_shopify', value: 2.hours.ago.iso8601, tenant_id: Current.tenant_id)

    captured_since = nil
    CatalogSyncer.stubs(:sync!).with do |args|
      captured_since = args[:since]
      true
    end
                 .returns({ products: 1, variants: 1, orders: { 'nodes' => [] } })
    LedgerImporter.stubs(:from_shopify_orders!).returns(nil)
    SquareClient.stubs(:configured?).returns(false)
    AlertGenerator.stubs(:sync!).returns({ created: 0, resolved: 0 })

    SyncEngine.run!(mode: 'backfill', actor: 'rake', history_days: 365)

    assert_equal (Time.current - 365.days).strftime('%Y-%m-%d'), captured_since
  end

  test 'a failed sync does not advance the watermark' do
    ShopifyClient.stubs(:configured?).returns(true)
    CatalogSyncer.stubs(:sync!).raises(StandardError, 'Shopify down')
    SquareClient.stubs(:configured?).returns(false)

    assert_raises(StandardError) { SyncEngine.run!(mode: 'scheduled', actor: 'scheduler') }

    assert_nil Setting.find_by(key: 'sync_watermark_shopify', tenant_id: Current.tenant_id)
  end
end
