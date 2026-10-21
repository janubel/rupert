# frozen_string_literal: true

module OpsLog
  # Keeps the warnings and errors an operator should look at in the database
  # (OpsEvent), so the System page and the recent_errors tool see the web server and
  # the job worker alike, across restarts. Repeats of the same problem within a
  # window are counted on one row instead of adding rows. The data is the event's own
  # already-redacted fields.
  module Activity
    KINDS = {
      'request' => 'Request problem', 'permission_denied' => 'Permission denied', 'validation_failed' => 'Form rejected',
      'auth' => 'Sign-in', 'job' => 'Background job', 'exception' => 'Unexpected error', 'sync' => 'Sync',
      'upload' => 'Upload', 'rate_limited' => 'Rate limited', 'mcp_tool_call' => 'Assistant tool call', 'import' => 'Import'
    }.freeze
    FINGERPRINT_FIELDS = %i[controller action status model error_class source operation job_class tool outcome reason kind].freeze
    DEDUPE_WINDOW = 10.minutes
    MAX_ROWS = 5000

    CATEGORIES = {
      'server_error' => 'Server errors', 'slow_request' => 'Slow requests', 'client_error' => 'Rejected requests',
      'permission_denied' => 'Permission denials', 'rejected_form' => 'Rejected forms', 'sign_in_failure' => 'Sign-in failures',
      'job_failure' => 'Job failures', 'sync_failure' => 'Sync failures', 'import_problem' => 'Import problems',
      'exception' => 'Unexpected errors', 'rate_limited' => 'Rate limited', 'assistant_tool' => 'Assistant tool errors', 'other' => 'Other'
    }.freeze

    class << self
      def category(name, fields)
        case name
        when 'request' then fields[:status].to_i >= 500 ? 'server_error' : (fields[:slow] ? 'slow_request' : 'client_error')
        when 'permission_denied' then 'permission_denied'
        when 'validation_failed' then 'rejected_form'
        when 'auth' then 'sign_in_failure'
        when 'job', 'job_retry', 'job_retry_exhausted', 'job_discarded' then 'job_failure'
        when 'sync' then 'sync_failure'
        when 'import', 'upload' then 'import_problem'
        when 'exception' then 'exception'
        when 'rate_limited' then 'rate_limited'
        when 'mcp_tool_call', 'ask_rupert_tool', 'ask_rupert' then 'assistant_tool'
        else 'other'
        end
      end

      def record(name, level, fields)
        return unless defined?(OpsEvent) && enabled?

        OpsEvent.record!(
          kind: name, category: category(name, fields), level: level.to_s, summary: summary(name, fields), fingerprint: fingerprint(name, fields),
          tenant_id: fields[:tenant_id]&.to_s, user_id: fields[:user_id], request_id: fields[:request_id], data: fields
        )
      rescue StandardError
        nil
      end

      def enabled? = ENV['RUPERT_OPS_EVENTS'] != '0'

      def retention_days = (ENV['RUPERT_OPS_EVENT_DAYS'].presence || 14).to_i

      def fingerprint(name, fields)
        Digest::SHA256.hexdigest(([name] + fields.values_at(*FINGERPRINT_FIELDS).map(&:to_s)).join('|')).first(24)
      end

      # One short line for a card row. Built from names and codes only.
      def summary(name, fields)
        where = [fields[:controller], fields[:action]].compact.join('#').presence
        head = case name
        when 'request' then [fields[:method], fields[:route] || fields[:path], fields[:status]].compact.join(' ')
        when 'job' then [fields[:job_class], fields[:queue] && "on #{fields[:queue]}"].compact.join(' ')
        when 'sync' then [fields[:source], fields[:operation], fields[:outcome], fields[:category]].compact.join(' ')
        when 'permission_denied' then ["#{fields[:role] || 'someone'} refused", fields[:policy], fields[:query]].compact.join(' ')
        when 'auth' then [fields[:source], fields[:status], fields[:reason]].compact.join(' ')
        when 'validation_failed' then "#{fields[:model]} #{Array(fields[:fields]).first(4).join(', ')}".strip
        else fields[:reason] || fields[:kind] || fields[:tool]
        end
        [head, where && "(#{where})", fields[:error_class]].compact_blank.join(' ').first(240)
      end
    end
  end
end
