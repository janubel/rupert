# frozen_string_literal: true

# What each backup layer last reported, for System → Backups and the MCP
# backup_freshness tool. The scripts (bin/backup.sh, deploy/ser8/*, deploy/offsite/*)
# each write one small JSON file into storage/backups/<layer>.json after every
# run; the app only reads them. A layer with no file has never reported here,
# which is itself something to show: a mirror that was never installed is a gap,
# not a quiet success.
class BackupStatus
  Report = Struct.new(:state, :at, :message, :file, :bytes, :kept, :free_bytes, :host, keyword_init: true)

  Layer = Struct.new(:key, :label, :protects, :every, :stale_after, :report, keyword_init: true) do
    def reported? = report.present?

    # ok · failed · stale (last report older than stale_after) · missing (never reported)
    def state(now = Time.current)
      return 'missing' unless reported?
      return 'failed' if report.state == 'failed'
      return 'stale' if report.at.nil? || report.at < now - stale_after

      'ok'
    end

    def ok?(now = Time.current) = state(now) == 'ok'
  end

  LAYERS = [
    { key: 'frequent', label: 'Rolling snapshot', every: 'every 5 minutes',
      protects: 'The last day of mistakes: a bad import, a deleted record, a migration gone wrong.', stale_after: 20.minutes },
    { key: 'local', label: 'Local backup set', every: 'every 6 hours',
      protects: 'Database, settings dump and encryption keys together, so a restore can read encrypted settings.', stale_after: 7.hours },
    { key: 'offhost', label: 'Encrypted copy outside the container', every: 'every 6 hours',
      protects: 'Loss or corruption of the container. Encrypted with a key kept in the password manager.', stale_after: 7.hours },
    { key: 'offsite', label: 'Mirror on another machine', every: 'every 6 hours while the mirror is on',
      protects: 'Loss of the server disk, the server, or the building.', stale_after: 48.hours },
    { key: 'verify', label: 'Restore drill', every: 'weekly',
      protects: 'Backups that cannot be restored: the newest copy is decrypted and checked end to end.', stale_after: 8.days }
  ].freeze

  class << self
    def dir = Pathname(ENV.fetch('RUPERT_BACKUP_STATUS_DIR', Rails.root.join('storage/backups').to_s))

    def layers
      LAYERS.map { |attrs| Layer.new(**attrs, report: read(attrs[:key])) }
    end

    # One word for the card header: ok when every layer is fresh, otherwise the worst state present.
    def summary(layers = self.layers, now: Time.current)
      states = layers.map { |layer| layer.state(now) }
      %w[failed stale missing].find { |state| states.include?(state) } || 'ok'
    end

    def read(key)
      data = JSON.parse(dir.join("#{key}.json").read)
      return unless data.is_a?(Hash)

      Report.new(state: data['state'].to_s, at: parse_time(data['at']), message: data['message'].to_s,
        file: data['file'].to_s, bytes: data['bytes'].to_i, kept: data['kept'].to_i,
        free_bytes: data['free_bytes'].to_i, host: data['host'].to_s)
    rescue Errno::ENOENT, Errno::EACCES, Errno::ENOTDIR, Errno::EISDIR, JSON::ParserError
      nil
    end

    private

    def parse_time(value)
      Time.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end
  end
end
