# frozen_string_literal: true

# Orchestrates sync runs against both platforms for a single tenant, mirroring
# everything into the database and recording each run in the SyncRun table.
# Guarded so only one sync runs per tenant at a time (DB-level, survives
# restarts).
class SyncEngine
  class AlreadyRunning < StandardError; end

  # Generous enough to cover backfills that legitimately run for a while; the
  # per-tenant unique index (not this window) is what stops overlapping syncs.
  # A run stuck past this is genuinely hung (scheduled syncs fire every 15
  # minutes and normally finish in ~1 minute) and would otherwise block the
  # whole schedule until the worker restarts.
  STALE_RUN_AFTER = 45.minutes

  # Incremental order imports: every scheduled sync re-fetches only orders
  # newer than the last successful import, minus this tail so late fulfillment
  # updates and stragglers still get caught. Manual backfills
  # (ops:backfill[DAYS], or any explicit history_days) bypass the watermark.
  REFRESH_TAIL = 48.hours

  class << self
    def run!(mode: 'manual', actor: 'user', tenant: nil, history_days: nil)
      Current.tenant = tenant if tenant
      raise ArgumentError, 'No tenant in context' if Current.tenant_id.nil?

      # Recover any orphaned running run BEFORE we try to start a new one so a
      # hung/failed worker can't hold the per-tenant lock indefinitely. This
      # is what keeps the 15-minute schedule alive across worker restarts.
      recover_stale_runs!

      run = create_run!(mode: mode, source: 'all', actor: actor)
      Current.sync_run = run

      begin
        summary = {}
        shopify = CatalogSyncer.sync!(since: order_since('shopify', history_days))
        summary[:shopify] = { products: shopify[:products], variants: shopify[:variants] }
        if (oversold = shopify[:oversold_variants]).to_i.positive?
          summary[:shopify][:oversold_variants] = oversold
        end
        LedgerImporter.from_shopify_orders!(shopify.dig(:orders, 'nodes'))
        advance_watermark!('shopify', run.startedAt)

        # Square syncs are read-only mirrors (Square -> local DB) and always run
        # when configured; the freeze only blocks *writes* to Square.
        if SquareClient.configured?
          square = SquareSyncer.sync!(since: order_since('square', history_days))
          summary[:square] = { locations: square[:locations].length, orders: square[:orders].length }
          LedgerImporter.from_square_orders!(square[:orders])
          advance_watermark!('square', run.startedAt)
        else
          summary[:square] = { status: 'skipped', reason: 'Square is not configured' }
        end

        AlertGenerator.sync!
        # NOTE: no quantity equalization here. Shopify and Square are separate
        # locations with independent inventories; the old lock-step machinery
        # (Reconciler plan, InventoryMaintainer pool push) was removed.
        # Outbound stock writes happen only through explicit, owner-approved
        # flows (size-family derives, remediation tasks).

        run.update!(status: 'success', finishedAt: Time.current, details: summary.to_json)
        bump_cache_logging_only
        run
      rescue StandardError => e
        run.update!(status: 'failed', error: e.message.to_s[0, 2000], finishedAt: Time.current)
        raise
      ensure
        Current.sync_run = nil
      end
    end

    def run_source!(source, actor: 'user', tenant: nil)
      Current.tenant = tenant if tenant
      raise ArgumentError, 'No tenant in context' if Current.tenant_id.nil?
      raise ArgumentError, 'Unknown sync source' unless %w[shopify square].include?(source)

      recover_stale_runs!
      run = create_run!(mode: 'manual', source: source, actor: actor)
      Current.sync_run = run

      begin
        if source == 'square'
          raise SquareClient::Error, 'SQUARE_ACCESS_TOKEN is not set' unless SquareClient.configured?

          # A Square sync is a read-only mirror and runs even while Square is
          # frozen (the freeze only blocks outbound writes).
          square = SquareSyncer.sync!(since: order_since('square', nil))
          LedgerImporter.from_square_orders!(square[:orders])
        else
          shopify = CatalogSyncer.sync!(since: order_since('shopify', nil))
          LedgerImporter.from_shopify_orders!(shopify.dig(:orders, 'nodes'))
        end
        advance_watermark!(source, run.startedAt)
        run.update!(status: 'success', finishedAt: Time.current, details: { source: source }.to_json)
        bump_cache_logging_only
        run
      rescue StandardError => e
        run.update!(status: 'failed', error: e.message.to_s[0, 2000], finishedAt: Time.current)
        raise
      ensure
        Current.sync_run = nil
      end
    end

    def running?
      SyncRun.unscoped.where(tenant_id: Current.tenant_id, status: 'running').exists?
    end

    # One-way import of a SwipeSimple CSV export (SwipeSimple has no public
    # API). Idempotent, synchronous, and recorded as a sync run.
    def import_swipesimple_csv!(csv_text_or_path, actor: 'user', tenant: nil, expected_fingerprint: nil)
      Current.tenant = tenant if tenant
      raise ArgumentError, 'No tenant in context' if Current.tenant_id.nil?

      recover_stale_runs!
      run = create_run!(mode: 'csv', source: 'swipesimple', actor: actor)
      Current.sync_run = run
      summary = SwipesimpleImporter.import!(csv_text_or_path, expected_fingerprint: expected_fingerprint) do |result|
        run.update!(status: 'success', finishedAt: Time.current, details: result.to_h.to_json)
      end
      bump_cache_logging_only
      summary
    rescue StandardError => e
      message = e.is_a?(ArgumentError) || e.is_a?(AlreadyRunning) ? e.message.to_s[0, 2000] : 'The CSV import failed. No sales were saved.'
      run&.update!(status: 'failed', error: message, finishedAt: Time.current)
      raise
    ensure
      Current.sync_run = nil
    end

    private

    def backfill_since(history_days)
      return nil if history_days.nil?

      (Time.current - history_days.days).strftime('%Y-%m-%d')
    end

    # The `since` for a source's order fetch. Explicit history_days (manual
    # backfill) always wins; otherwise the per-source watermark from the last
    # successful import, minus REFRESH_TAIL so late fulfillment updates and
    # stragglers are re-fetched. No watermark yet -> nil -> the syncer's
    # default lookback (first run / fresh tenant).
    def order_since(source, history_days)
      return backfill_since(history_days) if history_days.present?

      watermark = read_watermark(source)
      return nil if watermark.nil?

      since = watermark - REFRESH_TAIL
      source == 'square' ? since.iso8601 : since.strftime('%Y-%m-%d')
    end

    def read_watermark(source)
      value = Setting.find_by(key: watermark_key(source), tenant_id: Current.tenant_id)&.value
      value.present? ? Time.zone.parse(value) : nil
    rescue ArgumentError, TypeError
      nil
    end

    # Advances only after a successful import. A failure here is logged and
    # swallowed: the safe direction is to re-import (idempotent upserts), never
    # to skip data.
    def advance_watermark!(source, to_time)
      Setting.create_with(value: to_time.iso8601)
             .find_or_create_by!(key: watermark_key(source), tenant_id: Current.tenant_id)
             .update!(value: to_time.iso8601)
    rescue StandardError => e
      Rails.logger.warn("SyncEngine: could not advance #{source} watermark (orders will be re-imported next run): #{e.class}: #{e.message}")
    end

    def watermark_key(source)
      "sync_watermark_#{source}"
    end

    # A data-version cache bump is a best-effort side effect: mirrored data has
    # already persisted and the run is marked success before this runs. A cache-
    # store failure (e.g. file-cache permissions) must never flip the run to
    # failed or raise through to a spurious "Sync failed" notification, so log
    # and swallow it here. The DB-backed Setting row still bumps; the cache just
    # refreshes lazily on next read.
    def bump_cache_logging_only
      DataCache.bump!
    rescue StandardError => e
      Rails.logger.warn("SyncEngine: DataCache.bump! failed (sync already succeeded): #{e.class}: #{e.message}")
    end

    # The running-run guard is enforced by a per-tenant partial unique index:
    # the insert itself is the lock. A race is caught as RecordNotUnique and
    # retried after stale runs are cleared, so two threads can never sync the
    # same tenant concurrently.
    def create_run!(mode:, source:, actor:)
      run = SyncRun.new(mode: mode, status: 'running', source: source, actor: actor, startedAt: Time.current)
      run.save!
      run
    rescue ActiveRecord::RecordNotUnique
      recover_stale_runs!
      raise AlreadyRunning, 'A sync is already running' if running?

      retry
    end

    def recover_stale_runs!
      cutoff = STALE_RUN_AFTER.ago
      SyncRun.unscoped.where(tenant_id: Current.tenant_id, status: 'running').where('"startedAt" < ?', cutoff).update_all(
        status: 'failed',
        finishedAt: Time.current,
        error: "Automatically recovered stale sync after #{STALE_RUN_AFTER.inspect}"
      )
    end
  end
end
