# frozen_string_literal: true

# Error tracking. Completely inert unless SENTRY_DSN is set in the environment
# (/etc/rupert.env on SER8). Request bodies, cookies, headers and user emails
# are never sent; the release is the deployed build SHA so an alert names the
# exact revision.
if ENV['SENTRY_DSN'].present?
  Sentry.init do |config|
    config.dsn = ENV['SENTRY_DSN']
    config.environment = ENV.fetch('SENTRY_ENVIRONMENT', Rails.env)
    config.release = BuildInfo.current.revision if defined?(BuildInfo)
    config.breadcrumbs_logger = [:active_support_logger]
    config.send_default_pii = false
    config.traces_sample_rate = ENV.fetch('SENTRY_TRACES_SAMPLE_RATE', '0').to_f
    config.excluded_exceptions += %w[ActionController::RoutingError ActionController::InvalidAuthenticityToken
      ActiveRecord::RecordNotFound Rack::Attack::Throttled]
    config.before_send = lambda do |event, _hint|
      event.request&.data = nil
      event.request&.cookies = nil
      event.request&.headers = event.request&.headers&.slice('User-Agent', 'X-Request-Id')
      event
    end
  end
end
