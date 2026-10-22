# frozen_string_literal: true

# Captures what OpsLog writes while a block runs, as parsed JSON lines, using a plain
# Logger tap (never a tagged one: see the BroadcastLogger note in request_trace.rb).
module OpsLogHelper
  def capture_ops_log(format: 'json', level: Logger::INFO)
    io = StringIO.new
    tap_logger = Logger.new(io, level: level)
    tap_logger.formatter = Logger::Formatter.new.tap { |formatter| formatter.extend(OpsLog::Formatter) }
    Rails.logger.broadcast_to(tap_logger)
    OpsLog.with_format(format) { yield }
    @ops_raw = io.string
    io.string.lines.map { |line| JSON.parse(line.sub(/\A<\d>/, '')) }
  ensure
    Rails.logger.stop_broadcasting_to(tap_logger)
  end

  def ops_raw = @ops_raw.to_s

  def ops_events(lines, name) = lines.select { |line| line['event'] == name }
end
