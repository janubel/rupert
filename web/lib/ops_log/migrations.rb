# frozen_string_literal: true

module OpsLog
  # `db:migrate` runs on every deploy (rupert-autodeploy). These events say which schema
  # versions were pending, what moved and how long it took, or that it failed, so a deploy
  # can be followed in the same JSON log as everything else. Nothing here may raise: a
  # logging bug must never fail a migration.
  module Migrations
    class << self
      def started
        context = ActiveRecord::Base.connection_pool.migration_context
        pending = context.migrations.map(&:version) - context.get_all_versions
        @run = { at: Process.clock_gettime(Process::CLOCK_MONOTONIC), from: context.current_version, pending: pending }
        OpsLog.event('db.migrate', persist: false, phase: 'started', current_version: @run[:from], pending: @run[:pending].first(20), pending_count: @run[:pending].size)
        at_exit { failed($!) if @run }
      rescue StandardError
        @run = nil
      end

      def finished
        return unless @run

        run = @run
        @run = nil
        to = ActiveRecord::Base.connection_pool.migration_context.current_version
        OpsLog.event('db.migrate', persist: false, phase: 'finished', outcome: 'ok', from_version: run[:from], to_version: to, applied: run[:pending].size,
          duration_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - run[:at]) * 1000).round)
      rescue StandardError
        nil
      end

      def failed(error)
        run = @run
        @run = nil
        OpsLog.event('db.migrate', level: :error, phase: 'finished', outcome: 'failed', from_version: run&.dig(:from), **OpsLog.error_fields(error),
          duration_ms: (run ? ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - run[:at]) * 1000).round : nil))
      rescue StandardError
        nil
      end
    end
  end
end
