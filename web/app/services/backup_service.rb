# frozen_string_literal: true

require 'fileutils'

# Instance snapshot downloads for the Settings GUI and backup jobs. SQLite
# uses VACUUM INTO; PostgreSQL uses pg_dump. Restore requires offline maintenance.
class BackupService
  class RestoreError < StandardError; end

  class << self
    def database_path
      ActiveRecord::Base.connection_db_config.database
    end

    def snapshot_path
      dir = Rails.root.join('tmp', 'backups')
      FileUtils.mkdir_p(dir, mode: 0o700)
      File.chmod(0o700, dir)
      if postgres?
        postgres_snapshot_path(dir)
      else
        sqlite_snapshot_path(dir)
      end
    end

    def restore!(_source_path)
      # A request cannot quiesce other web/job writers. Even a transactional
      # PostgreSQL restore can discard writes committed since its recovery dump;
      # replaying that older dump after a failed restore makes the loss worse.
      raise RestoreError, 'Database restore requires offline maintenance with web and jobs stopped and a verified consistent recovery backup. No database files were changed.'
    end

    def postgres?
      ActiveRecord::Base.connection_db_config.adapter == 'postgresql'
    end

    private

    def sqlite_snapshot_path(dir)
      path = dir.join("rupert-backup-#{Time.now.to_i}-#{SecureRandom.hex(12)}.sqlite3")
      connection = ActiveRecord::Base.connection
      quoted = connection.quote(path.to_s)
      connection.execute("VACUUM INTO #{quoted}")
      File.chmod(0o600, path)
      path
    end

    def postgres_snapshot_path(dir)
      path = dir.join("rupert-backup-#{Time.now.to_i}-#{SecureRandom.hex(12)}.dump")
      config = ActiveRecord::Base.connection_db_config.configuration_hash
      cmd = ['pg_dump', '--format=custom', '--no-owner', "--file=#{path}"]
      cmd << "--host=#{config[:host]}" if config[:host].present?
      cmd << "--port=#{config[:port]}" if config[:port].present?
      cmd << "--username=#{config[:username]}" if config[:username].present?
      cmd << config[:database]
      env = { 'PGPASSWORD' => config[:password].to_s }
      ok = system(env, *cmd, out: File::NULL, err: File::NULL)
      unless ok && File.exist?(path) && !File.empty?(path)
        FileUtils.rm_f(path)
        raise RestoreError, 'pg_dump failed — is PostgreSQL running?'
      end

      File.chmod(0o600, path)
      path
    end
  end
end
