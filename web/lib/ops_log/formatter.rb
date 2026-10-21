# frozen_string_literal: true

module OpsLog
  # Extended onto the logger's formatter AFTER ActiveSupport::TaggedLogging (whose own
  # `call` would flatten a structured event into a string), so it wins the method lookup.
  # Every line becomes one JSON object: ts, level, event, fields. Plain strings that
  # other code logs become {"event":"log","msg":...} with the same redaction as events.
  module Formatter
    # Priority prefixes systemd-journald reads from stdout, so `journalctl -p warning` works.
    PRIORITY = { 'DEBUG' => 7, 'INFO' => 6, 'WARN' => 4, 'ERROR' => 3, 'FATAL' => 2 }.freeze
    MAX_MESSAGE = 4000
    REQUEST_TAG = /\[\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\]\s*/

    def call(severity, time, _progname, message)
      record = OpsLog::Formatter.record(severity, time, message, tags: respond_to?(:current_tags) ? current_tags : [])
      line = JSON.generate(record)
      prefix = ENV['JOURNAL_STREAM'] ? "<#{PRIORITY.fetch(severity.to_s, 6)}>" : ''
      "#{prefix}#{line}\n"
    rescue StandardError
      "#{{ ts: Time.now.utc.iso8601(3), level: severity.to_s.downcase, event: 'log', msg: 'unformattable log line' }.to_json}\n"
    end

    class << self
      def record(severity, time, message, tags: [])
        base = { ts: time.utc.iso8601(3), level: severity.to_s.downcase }
        if message.is_a?(OpsLog::Event)
          fields = message.fields.dup
          fields[:request_id] ||= tags.first if tags.first
          base.merge(event: message.name).merge(fields)
        else
          base.merge(event: 'log', request_id: OpsLog.context[:request_id] || tags.first, msg: message_text(message)).compact
        end
      end

      def message_text(message)
        text = case message
        when String then message
        when Exception then "#{message.class}: #{message.message}"
        else message.inspect
        end
        OpsLog.safe_text(text.gsub(REQUEST_TAG, ''), MAX_MESSAGE, strict: false)
      end
    end
  end
end
