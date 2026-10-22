# frozen_string_literal: true

# Structured operational logging (docs/ops/logging.md). Production writes one JSON
# object per line; development keeps Rails' readable log. Must load before
# request_trace.rb, which inserts its middleware relative to OpsLog::RackLogger.
#
# A failure here must never stop the app booting (a failed boot rolls back a deploy),
# so installation falls back to Rails' default logging and says why on stderr.
require Rails.root.join('lib/ops_log')

begin
  Rails.application.config.middleware.swap(Rails::Rack::Logger, OpsLog::RackLogger, Rails.application.config.log_tags)
  # The structured request and exception events replace Rails' multi-line exception dump
  # (which a JSON line would carry as one 4 KB string); RAILS_LOG_LEVEL=debug brings it back.
  Rails.application.config.action_dispatch.debug_exception_log_level = :debug if OpsLog.single_line?
  if OpsLog.json?
    Rails.logger.broadcasts.each do |logger|
      logger.formatter&.extend(OpsLog::Formatter)
    end
  end
  Rails.application.config.after_initialize do
    OpsLog::Subscribers.install!
    OpsLog.boot_event
  rescue StandardError => e
    warn "OpsLog subscribers could not be installed (#{e.class}: #{e.message})."
  end
rescue StandardError => e
  warn "OpsLog could not be installed (#{e.class}); using Rails default logging."
  OpsLog.format = 'rails'
end
