# frozen_string_literal: true

require 'fileutils'

# Instance snapshot downloads for the Settings GUI and backup jobs. SQLite
# snapshots use VACUUM INTO; restore requires offline maintenance.
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
      sqlite_snapshot_path(dir)
    end

    def restore!(_source_path)
      # A request cannot quiesce other web/job writers. Even a transactional
      # restore can discard writes committed since its recovery backup; replaying
      # that older snapshot after a failed restore makes the loss worse.
      raise RestoreError, 'Database restore requires offline maintenance with web and jobs stopped and a verified consistent recovery backup. No database files were changed.'
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
  end
end
