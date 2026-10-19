# frozen_string_literal: true

# Rack endpoint behind GET /up. Answers 200 only when the app can actually
# reach its database; otherwise 503, so the proxy, Incus checks and the host
# watcher see a dead database instead of a cheerful "OK". No authentication,
# no details beyond a short status word, and no writes.
class HealthCheck
  HEADERS = { 'content-type' => 'text/plain', 'cache-control' => 'no-store' }.freeze

  def self.call(_env)
    database_reachable!
    [200, HEADERS.dup, ['OK']]
  rescue StandardError => e
    Rails.logger.error("[health] database check failed: #{e.class}")
    [503, HEADERS.dup, ['DATABASE UNAVAILABLE']]
  end

  def self.database_reachable!
    ActiveRecord::Base.connection_pool.with_connection { |connection| connection.select_value('SELECT 1') }
  end
end
