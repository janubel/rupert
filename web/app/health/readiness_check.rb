# frozen_string_literal: true


# Rack endpoint behind GET /up/ready. Answers 200 only when the app can serve
# a shop right now: database reachable, a Solid Queue worker heartbeat within
# the last few minutes, the newest successful sync not older than the stale
# window, and free disk on the database volume above the floor. Otherwise 503
# with one status word per check and no other detail. No authentication and
# no writes, like /up.
class ReadinessCheck
  HEADERS = { 'content-type' => 'application/json', 'cache-control' => 'no-store' }.freeze
  WORKER_HEARTBEAT_WINDOW = 3.minutes
  STALE_SYNC_AFTER = 45.minutes # three missed 15-minute schedules
  MIN_FREE_DISK_MB = 1024
  SYNC_SOURCES = %w[all shopify].freeze

  def self.call(_env)
    checks = {
      'database' => database_status,
      'worker' => worker_status,
      'last_sync' => sync_status,
      'disk' => disk_status
    }
    ok = checks.values.all? { |status| status == 'ok' || status == 'unconfigured' }
    body = { 'status' => ok ? 'ready' : 'not_ready', 'checks' => checks }.to_json
    [ok ? 200 : 503, HEADERS.dup, [body]]
  rescue StandardError => e
    Rails.logger.error("[readiness] failed: #{e.class}")
    [503, HEADERS.dup, [{ 'status' => 'not_ready', 'checks' => { 'database' => 'error' } }.to_json]]
  end

  def self.database_status
    ActiveRecord::Base.connection_pool.with_connection { |connection| connection.select_value('SELECT 1') }
    'ok'
  rescue StandardError
    'unavailable'
  end

  # Solid Queue's process table is the worker's heartbeat regardless of which
  # Active Job adapter the current process uses.
  def self.worker_status
    return 'unconfigured' unless defined?(SolidQueue::Process) && SolidQueue::Process.table_exists?

    beat = SolidQueue::Process.where(kind: 'Worker').maximum(:last_heartbeat_at)
    return 'missing' if beat.nil?

    beat > WORKER_HEARTBEAT_WINDOW.ago ? 'ok' : 'stale'
  rescue StandardError
    'unavailable'
  end

  # Newest successful sync across all workspaces that have Shopify configured.
  # A fresh install with no sync yet is 'unconfigured', not a failure.
  def self.sync_status
    scope = SyncRun.unscoped.where(status: 'success', source: SYNC_SOURCES)
    return 'unconfigured' unless scope.exists?

    latest = scope.maximum(:startedAt)
    latest > STALE_SYNC_AFTER.ago ? 'ok' : 'stale'
  rescue StandardError
    'unavailable'
  end

  def self.disk_status
    path = database_directory
    return 'unconfigured' if path.nil?

    free_mb = free_megabytes(path)
    return 'unavailable' if free_mb.nil?

    free_mb >= MIN_FREE_DISK_MB ? 'ok' : 'low'
  end

  def self.database_directory
    database = ActiveRecord::Base.connection_db_config.database.to_s
    return nil if database == ':memory:'

    File.dirname(database.start_with?('/') ? database : Rails.root.join(database).to_s)
  end

  # Free space in MB via POSIX df (portable across the Alpine image and Ubuntu
  # hosts; avoids a gem). Returns nil when df is unavailable.
  def self.free_megabytes(path)
    output = IO.popen(['df', '-Pk', path], err: File::NULL, &:read)
    line = output.to_s.lines.last
    kilobytes = line&.split&.fetch(3, nil)
    kilobytes&.match?(/\A\d+\z/) ? kilobytes.to_i / 1024 : nil
  rescue StandardError
    nil
  end
end
