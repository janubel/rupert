# frozen_string_literal: true

module Mcp
  module Tools
    class SyncHealth < Tool
      tool 'sync_health',
        title: 'Source sync health',
        description: 'How fresh is each connected source (Shopify, Square, C-Trax, SwipeSimple, Authorize.net, bank reports)? ' \
                     'Per source and operation: the latest attempt, its status and failure category, and when it last ' \
                     'succeeded; plus the latest catalog sync run and whether a queue worker is alive. No credentials or ' \
                     'messages. Read-only; needs the system:read scope.',
        scope: 'system:read'

      def call(_args)
        rows = SyncAttempt.where.not(source: 'google_backup').group(:source, :operation).count.keys.map { |source, operation| channel(source, operation) }
        run = SyncRun.order(startedAt: :desc).first
        data = {
          channels: rows.sort_by { |row| [row[:source], row[:operation]] },
          latest_catalog_run: run && { source: run.source, status: run.status, started_at: iso(run.startedAt), finished_at: iso(run.try(:finishedAt)) },
          queue_worker: SyncQueueHealth.worker.then { |worker| { state: worker[:state], last_heartbeat_at: iso(worker[:last_at]) } },
          generated_at: iso(Time.current)
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
          latest_at: iso(latest&.finished_at || latest&.started_at || latest&.queued_at), last_success_at: iso(success&.finished_at) }
      end
    end
  end
end
