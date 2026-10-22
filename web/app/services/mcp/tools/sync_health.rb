# frozen_string_literal: true

require 'time'

module Mcp
  module Tools
    class SyncHealth < Tool
      FEEDS = {
        ['shopify', 'catalog'] => %w[sales orders inventory],
        ['square', 'catalog'] => %w[sales orders inventory],
        ['ctrax', 'stock'] => %w[inventory],
        ['ctrax', 'sales'] => %w[sales],
        ['ctrax', 'timecards'] => %w[timekeeping],
        ['square', 'timecards'] => %w[timekeeping],
        ['swipesimple', 'web'] => %w[sales payments deposits],
        ['bank', 'web'] => %w[bank deposits],
        ['bank', 'reporting'] => %w[bank deposits],
        ['authorize_net', 'reporting'] => %w[payments deposits]
      }.freeze

      tool 'sync_health',
        title: 'Source sync health',
        description: 'How fresh is each connected source (Shopify, Square, C-Trax, SwipeSimple, Authorize.net, bank reports)? ' \
                     'Per source and operation: the latest attempt, its status and failure category, and when it last ' \
                     'succeeded, which figures each operation feeds, and whether a fully-synced-through day is known; ' \
                     'plus the latest catalog sync run and whether a queue worker is alive. Acquisition time alone does ' \
                     'not prove complete sales coverage. No credentials or ' \
                     'messages. Read-only; needs the system:read scope.',
        scope: 'system:read'

      def call(_args)
        rows = SyncAttempt.where.not(source: 'google_backup').group(:source, :operation).count.keys.map { |source, operation| channel(source, operation) }
        run = SyncRun.order(startedAt: :desc).first
        data = {
          channels: rows.sort_by { |row| [row[:source], row[:operation]] },
          latest_catalog_run: run && { source: run.source, status: run.status, started_at: iso(run.startedAt), finished_at: iso(run.try(:finishedAt)) },
          queue_worker: SyncQueueHealth.worker.then { |worker| { state: worker[:state], last_heartbeat_at: iso(worker[:last_at]) } },
          generated_at: iso(Time.current), yesterday_sync_healthy: yesterday_sync_healthy(rows),
          yesterday_complete: yesterday_complete(rows),
          completeness_note: 'A successful sync records an acquisition time, not a fully-synced-through date. ' \
                             'Rupert cannot prove every sale from yesterday is present until that coverage boundary is recorded.'
        }
        failing = rows.count { |row| row[:failing] }
        result("#{rows.size} source operation#{'s' unless rows.size == 1} tracked, #{failing} currently failing. Queue worker: #{data[:queue_worker][:state]}.", data)
      end

      private

      def channel(source, operation)
        scope = SyncAttempt.where(source: source, operation: operation)
        order = Arel.sql('COALESCE(started_at, queued_at) DESC')
        latest = scope.where.not(status: 'skipped').order(order, id: :desc).first
        success = scope.where(status: 'succeeded').order(order, id: :desc).first
        failing = latest&.status == 'failed'
        { source: source, operation: operation, latest_status: latest&.status, failing: failing, failure_category: (latest.error_category if failing),
          latest_at: iso(latest&.finished_at || latest&.started_at || latest&.queued_at), last_success_at: iso(success&.finished_at),
          feeds: FEEDS.fetch([source, operation], []), complete_through: nil, complete_through_known: false }
      end

      def yesterday_sync_healthy(rows)
        sales = rows.select { |row| row[:feeds].include?('sales') }
        cutoff = (Date.current - 1).in_time_zone.end_of_day
        sales.any? && sales.all? do |row|
          row[:latest_status] == 'succeeded' && row[:last_success_at].present? && Time.iso8601(row[:last_success_at]) >= cutoff
        end
      end

      def yesterday_complete(rows)
        sales = rows.select { |row| row[:feeds].include?('sales') }
        yesterday = Date.current - 1
        sales.any? && sales.all? do |row|
          row[:complete_through_known] && row[:complete_through].present? && Date.iso8601(row[:complete_through]) >= yesterday
        end
      end
    end
  end
end
