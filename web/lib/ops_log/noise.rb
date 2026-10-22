# frozen_string_literal: true

module OpsLog
  # Routine traffic that would drown the log: health probes, the provisioner's idle
  # poll, a monitor hitting the login redirect, quick recurring jobs. A quiet item is
  # written at debug and counted; one `noise_summary` event per window reports what was
  # held back, so the totals stay visible. Nothing here ever hides an error: callers only
  # offer successful, fast, ordinary items.
  module Noise
    # Anonymous visits to these answer with a redirect or the login form.
    PROBE_PATHS = ['/', '/login'].freeze
    IDLE_POLLS = [['POST', '/internal/workspaces/claim']].freeze

    @mutex = Mutex.new
    @counts = Hash.new { |hash, key| hash[key] = { count: 0, ms: 0.0 } }
    @window_started = nil

    class << self
      # True when a finished request is routine: a probe or poll that succeeded and was quick.
      def quiet_request?(method:, path:, status:, user_id:, duration_ms:)
        return false if status.to_i >= 400 || duration_ms.to_f >= OpsLog.slow_request_ms

        return true if path.start_with?('/up')
        return true if IDLE_POLLS.include?([method, path])

        user_id.nil? && method == 'GET' && PROBE_PATHS.include?(path)
      end

      def count(key, ms = 0.0)
        flush_due = nil
        @mutex.synchronize do
          @window_started ||= monotonic
          entry = @counts[key]
          entry[:count] += 1
          entry[:ms] += ms.to_f
          flush_due = flush_locked if monotonic - @window_started >= OpsLog.summary_seconds
        end
        emit(flush_due) if flush_due
      end

      # Writes the summary now (used on shutdown and in tests).
      def flush
        summary = @mutex.synchronize { flush_locked }
        emit(summary) if summary
      end

      def reset!
        @mutex.synchronize do
          @counts.clear
          @window_started = nil
        end
      end

      private

      def flush_locked
        return if @counts.empty?

        window = (monotonic - (@window_started || monotonic)).round
        items = @counts.sort_by { |_key, entry| -entry[:count] }.first(15).map do |key, entry|
          { what: key, count: entry[:count], total_ms: entry[:ms].round }
        end
        total = @counts.values.sum { |entry| entry[:count] }
        @counts.clear
        @window_started = monotonic
        { window_s: window, total: total, items: items }
      end

      def emit(summary)
        OpsLog.event('noise_summary', **summary)
      end

      def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
