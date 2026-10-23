# frozen_string_literal: true

# Server health for the platform administrator's status bar: CPU load, memory,
# disk use, database size and the last good backup. Read from /proc, df and the
# database file at most every 30 seconds (cached), so showing it on every page
# costs nothing. Any reading that cannot be taken is nil, never 0.
class HostVitals
  CACHE_KEY = 'host_vitals/v1'
  TTL = 30.seconds
  WARN = 80
  ALERT = 90

  Reading = Struct.new(:cpu, :memory, :disk, :db_bytes, :backup_bytes, :backup_at, :taken_at, keyword_init: true)

  class << self
    def current
      Rails.cache.fetch(CACHE_KEY, expires_in: TTL) { read }
    end

    def read
      backup = last_backup
      Reading.new(cpu: cpu_percent, memory: memory_percent, disk: disk_percent, db_bytes: database_bytes,
        backup_bytes: backup&.fileSize, backup_at: backup&.finishedAt, taken_at: Time.current)
    end

    # 'pill-fern' / 'pill-clay' / 'pill-rose' for a percentage.
    def tone(percent)
      return 'pill-taupe' if percent.nil?
      return 'pill-rose' if percent >= ALERT
      return 'pill-clay' if percent >= WARN

      'pill-fern'
    end

    private

    # One-minute load average as a share of the cores this process may use.
    def cpu_percent
      load1 = File.read('/proc/loadavg').split.first.to_f
      [(load1 / Etc.nprocessors * 100).round, 100].min
    rescue SystemCallError, ZeroDivisionError
      nil
    end

    def memory_percent
      info = File.read('/proc/meminfo').lines.to_h do |line|
        key, value = line.split(':')
        [key, value.to_i]
      end
      total = info['MemTotal'].to_i
      available = info['MemAvailable'].to_i
      total.positive? ? ((total - available) * 100.0 / total).round : nil
    rescue SystemCallError
      nil
    end

    # Use of the filesystem holding the database, as df reports it.
    def disk_percent
      output = IO.popen(['df', '-Pk', database_path.dirname.to_s], err: File::NULL, &:read)
      output.lines.last.to_s.split[4].to_s.delete('%').then { |value| value.match?(/\A\d+\z/) ? value.to_i : nil }
    rescue SystemCallError
      nil
    end

    def database_bytes
      path = database_path
      [path, Pathname("#{path}-wal")].sum { |file| file.file? ? file.size : 0 }.then { |bytes| bytes.positive? ? bytes : nil }
    end

    def database_path
      Pathname(ActiveRecord::Base.connection_db_config.database).expand_path(Rails.root)
    end

    def last_backup
      BackupLog.unscoped.where(tenant_id: nil, status: 'success').where.not(fileSize: nil).order(finishedAt: :desc).first
    end
  end
end
