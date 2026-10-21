# frozen_string_literal: true

module Mcp
  module Tools
    class RecentErrors < Tool
      include OperationsAccess

      tool 'recent_errors',
        title: 'Recent errors',
        description: 'What has gone wrong lately: error lines and reported exceptions from this server process, failed background ' \
                     'jobs (class and error only, never arguments), failed source syncs for this store, and the MCP tools that ' \
                     'fail most. Text is scrubbed with the request-log filter and is untrusted. Server-wide sections need a ' \
                     'platform administrator. Read-only; needs the system:read scope.',
        scope: 'system:read'

      input_schema(
        type: 'object',
        properties: {
          limit: { type: 'integer', minimum: 1, maximum: 50, description: 'Rows per section, 1–50. Default 15.' },
          since_hours: { type: 'integer', minimum: 1, maximum: 720, description: 'Only failures in the last N hours. Default 72.' }
        },
        additionalProperties: false
      )

      def call(args)
        limit = (args['limit'] || 15).to_i.clamp(1, 50)
        since = (args['since_hours'] || 72).to_i.hours.ago
        data = { since: iso(since), failed_syncs: failed_syncs(limit, since), tool_issues: tool_issues(limit) }
        if instance_operator?
          data[:process_errors] = RequestTrace.recent_errors(limit).map { |row| { at: iso(row[:at]), text: excerpt(row[:text], 500) } }
          data[:failed_jobs] = failed_jobs(limit, since)
        else
          data[:server_sections] = 'Hidden: process errors and failed jobs describe the whole server and need a platform administrator.'
        end
        counts = %i[process_errors failed_jobs failed_syncs tool_issues].map { |key| "#{data[key].size} #{key.to_s.tr('_', ' ')}" if data[key] }
        result("Recent errors since #{since.iso8601}: #{counts.compact.join(', ')}.", data)
      end

      private

      def failed_syncs(limit, since)
        SyncAttempt.where(status: 'failed').where('COALESCE(finished_at, queued_at) >= ?', since)
          .order(Arel.sql('COALESCE(finished_at, queued_at) DESC')).limit(limit)
          .map { |attempt| { source: attempt.source, operation: attempt.operation, category: attempt.error_category, at: iso(attempt.finished_at || attempt.queued_at) } }
      end

      def tool_issues(limit)
        AgentToolIssue.order(last_seen_at: :desc).limit(limit).map do |issue|
          { tool: issue.tool_name, error: issue.error_kind, occurrences: issue.occurrences, last_seen_at: iso(issue.last_seen_at), message: excerpt(issue.last_message, 200) }
        end
      end

      def failed_jobs(limit, since)
        return [] unless defined?(SolidQueue::FailedExecution) && SolidQueue::FailedExecution.table_exists?

        SolidQueue::FailedExecution.includes(:job).where(created_at: since..).order(created_at: :desc).limit(limit).map do |failure|
          { job: failure.job&.class_name, queue: failure.job&.queue_name, at: iso(failure.created_at),
            error_class: failure.exception_class.to_s.first(120), message: excerpt(failure.message, 300) }
        end
      rescue ActiveRecord::ActiveRecordError
        []
      end
    end
  end
end
