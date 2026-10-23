# frozen_string_literal: true

module TeamChat
  # Private operational facts only: never prompts, arguments, results, credentials or exception messages.
  class Telemetry < ApplicationRecord
    self.table_name = 'chat_telemetry'
    include TenantScoped
    # Recorder supplies both IDs; the foreign key checks existence without thread-local tenant scope.
    belongs_to :run, class_name: 'TeamChat::Run', optional: true

    def self.summary(run)
      run.reload
      rows = unscoped.where(run_id: run.id, tenant_id: run.tenant_id).order(:id).to_a
      usage = rows.select { |row| %w[provider_attempt cli_usage].include?(row.kind) }
      incomplete = rows.any? { |row| %w[running interrupted].include?(row.outcome) } ||
                   rows.any? { |row| row.kind == 'cli_inference' && row.facts.fetch('usage_reports', 0).zero? }
      fields = %w[input_tokens output_tokens cache_read_tokens cache_write_tokens thinking_tokens]
      counts = fields.to_h do |field|
        values = usage.map { |row| row.facts[field] }
        [field, { 'reported' => values.compact.presence&.sum, 'complete' => usage.any? && !incomplete && values.none?(&:nil?) }]
      end
      costs = usage.map { |row| row.facts['cost_usd'] }
      { 'state' => run.state, 'elapsed_ms' => ([(run.updated_at - run.created_at) * 1000, 0].max.round unless Run::ACTIVE.include?(run.state)), 'queue_ms' => rows.find { |row| row.kind == 'claim' }&.facts&.fetch('queue_ms', nil),
        'configuration' => run.configuration.slice('engine', 'model'),
        'duration_ms' => %w[execution inference cli_inference tool retry_wait].to_h do |kind|
          spans = rows.select { |row| row.kind == kind }
          values = spans.map(&:duration_ms)
          complete = values.any? && values.none?(&:nil?) && spans.none? { |row| %w[running interrupted].include?(row.outcome) }
          [kind, { 'reported' => values.compact.presence&.sum, 'complete' => complete }]
        end,
        'claims' => rows.count { |row| row.kind == 'claim' }, 'provider_attempts' => rows.count { |row| row.kind == 'provider_attempt' },
        'generation_retry_reservations' => rows.count { |row| row.kind == 'generation_retry' },
        'cli_invocations' => rows.count { |row| row.kind == 'cli_inference' },
        'transport_retries' => rows.select { |row| row.kind == 'generation' }.sum { |row| [row.facts.fetch('attempts', 0) - 1, 0].max },
        'tokens' => counts, 'reported_cost_usd' => costs.compact.presence&.sum,
        'cost_complete' => usage.any? && !incomplete && costs.none?(&:nil?),
        'failed_spans' => rows.count { |row| %w[failed cancelled interrupted expired].include?(row.outcome) } }
    end
  end
end
