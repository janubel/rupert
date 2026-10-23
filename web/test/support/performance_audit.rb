# frozen_string_literal: true

# Opt-in page performance audit (PERF_AUDIT=1 bin/rails test): while the normal
# suite runs, every controller action it exercises is recorded with its SQL
# query count, duration, the most repeated statement, and Rails' N+1 warnings
# (strict loading in :n_plus_one_only mode, logged not raised). Each test
# process writes JSON lines to tmp/perf_audit/; bin/perf-audit-report ranks them.
module PerformanceAudit
  DIR = Rails.root.join('tmp', 'perf_audit')
  IGNORED = %w[SCHEMA TRANSACTION].freeze

  module_function

  def enabled?
    ENV['PERF_AUDIT'] == '1'
  end

  def install!
    return unless enabled?

    FileUtils.mkdir_p(DIR)
    ActiveRecord::Base.strict_loading_by_default = true
    ActiveRecord::Base.strict_loading_mode = :n_plus_one_only
    ActiveRecord::Base.action_on_strict_loading_violation = :log

    ActiveSupport::Notifications.subscribe('start_processing.action_controller') do |*_args|
      Thread.current[:perf_audit] = { queries: 0, statements: Hash.new(0), n_plus_one: Hash.new(0) }
    end
    ActiveSupport::Notifications.subscribe('sql.active_record') do |*_args, payload|
      audit = Thread.current[:perf_audit]
      next unless audit && !payload[:cached] && !IGNORED.include?(payload[:name])

      audit[:queries] += 1
      audit[:statements][normalize(payload[:sql])] += 1
    end
    ActiveSupport::Notifications.subscribe('strict_loading_violation.active_record') do |*_args, payload|
      audit = Thread.current[:perf_audit]
      audit[:n_plus_one]["#{payload[:owner]}##{payload[:reflection].name}"] += 1 if audit
    end
    ActiveSupport::Notifications.subscribe('process_action.action_controller') do |_name, started, finished, _id, payload|
      audit = Thread.current[:perf_audit]
      Thread.current[:perf_audit] = nil
      next unless audit

      statement, repeats = audit[:statements].max_by { |_sql, count| count }
      record = { action: "#{payload[:controller]}##{payload[:action]}", format: payload[:format], status: payload[:status],
                 ms: ((finished - started) * 1000).round(1), view_ms: payload[:view_runtime]&.round(1),
                 queries: audit[:queries], repeats: repeats.to_i, repeated: statement.to_s.first(200),
                 n_plus_one: audit[:n_plus_one] }
      File.open(DIR.join("#{Process.pid}.jsonl"), 'a') { |file| file.puts(JSON.generate(record)) }
    end
  end

  def normalize(sql)
    sql.to_s.gsub(/'(?:[^']|'')*'/, '?').gsub(/\b\d+\b/, '?').gsub(/\(\s*\?(?:\s*,\s*\?)+\s*\)/, '(?)').squish
  end
end

PerformanceAudit.install!
