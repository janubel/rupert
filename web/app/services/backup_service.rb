# frozen_string_literal: true

require 'fileutils'

# SQLite backup/restore for the Settings GUI + JSON API. Backups use
# VACUUM INTO for a consistent snapshot even while writes are in flight.
class BackupService
  class RestoreError < StandardError; end

  # Reject absurd uploads before they reach the database.
  MAX_RESTORE_SIZE = 200.megabytes

  class << self
    def database_path
      ActiveRecord::Base.connection_db_config.database
    end

    def snapshot_path
      dir = Rails.root.join('tmp', 'backups')
      FileUtils.mkdir_p(dir)
      if postgres?
        postgres_snapshot_path(dir)
      else
        sqlite_snapshot_path(dir)
      end
    end

    def restore!(source_path)
      validate!(source_path)
      if postgres?
        postgres_restore!(source_path)
      else
        sqlite_restore!(source_path)
      end
      true
    end

    def validate!(source_path)
      raise RestoreError, 'Empty backup file' if source_path.nil? || File.empty?(source_path)
      if File.size(source_path) > MAX_RESTORE_SIZE
        raise RestoreError,
          "Backup is larger than #{MAX_RESTORE_SIZE / 1.megabyte} MB"
      end

      header = File.binread(source_path, 16).to_s
      valid = header.start_with?('SQLite format 3') || header.start_with?('PGDMP')
      raise RestoreError, 'Not a SQLite or PostgreSQL backup file' unless valid

      # A spoofed "PGDMP" header is trivial; make sure the archive is actually
      # restorable before anything is touched.
      return unless header.start_with?('PGDMP') && !pg_restore_list_ok?(source_path)

      raise RestoreError, 'PostgreSQL backup is corrupt or not a valid archive'
    end

    def postgres?
      ActiveRecord::Base.connection_db_config.adapter == 'postgresql'
    end

    private

    def sqlite_snapshot_path(dir)
      path = dir.join("rupert-backup-#{Time.now.to_i}.sqlite3")
      connection = ActiveRecord::Base.connection
      quoted = connection.quote(path.to_s)
      connection.execute("VACUUM INTO #{quoted}")
      path
    end

    def postgres_snapshot_path(dir)
      path = dir.join("rupert-backup-#{Time.now.to_i}.dump")
      config = ActiveRecord::Base.connection_db_config.configuration_hash
      cmd = ['pg_dump', '--format=custom', '--no-owner', "--file=#{path}"]
      cmd << "--host=#{config[:host]}" if config[:host].present?
      cmd << "--port=#{config[:port]}" if config[:port].present?
      cmd << "--username=#{config[:username]}" if config[:username].present?
      cmd << config[:database]
      env = { 'PGPASSWORD' => config[:password].to_s }
      ok = system(env, *cmd, out: File::NULL, err: File::NULL)
      raise RestoreError, 'pg_dump failed — is PostgreSQL running?' unless ok && File.exist?(path) && !File.empty?(path)

      path
    end

    # Restore is staged and reversible: the current database is snapshotted
    # first, the upload is pre-validated, and pg_restore runs in a single
    # transaction so a failure rolls back to the untouched original.
    def postgres_restore!(source_path)
      config = ActiveRecord::Base.connection_db_config.configuration_hash
      env = { 'PGPASSWORD' => config[:password].to_s }

      rollback = pg_dump_snapshot!(config, env, suffix: 'pre-restore')

      cmd = [
        'pg_restore',
        '--clean',
        '--if-exists',
        '--no-owner',
        '--single-transaction',
        "--host=#{config[:host]}",
        "--port=#{config[:port]}",
        "--username=#{config[:username]}",
        "--dbname=#{config[:database]}",
        source_path
      ]
      ok = system(env, *cmd, out: File::NULL, err: File::NULL)
      unless ok
        restore_rollback!(rollback, config, env)
        raise RestoreError, 'pg_restore failed — the backup may be corrupt (previous data restored from snapshot)'
      end

      ActiveRecord::Base.connection_pool.disconnect!
      ActiveRecord::Base.establish_connection
      verify_post_restore!
    end

    def sqlite_restore!(_source_path)
      # A web request cannot quiesce other Puma/job processes or safely replace
      # their open WAL database. Never offer a file-copy rollback as recovery.
      # Keep downloads available; restoration belongs to offline host maintenance.
      raise RestoreError, 'SQLite restore requires offline maintenance with web and jobs stopped and a verified consistent recovery backup. No database files were changed.'
    end

    def pg_restore_list_ok?(source_path)
      config = ActiveRecord::Base.connection_db_config.configuration_hash
      env = { 'PGPASSWORD' => config[:password].to_s }
      system(env, 'pg_restore', '--list', source_path, out: File::NULL, err: File::NULL)
    end

    def pg_dump_snapshot!(config, env, suffix:)
      dir = Rails.root.join('tmp', 'backups')
      FileUtils.mkdir_p(dir)
      path = dir.join("rupert-#{suffix}-#{Time.now.to_i}.dump")
      cmd = ['pg_dump', '--format=custom', '--no-owner', "--file=#{path}"]
      cmd << "--host=#{config[:host]}" if config[:host].present?
      cmd << "--port=#{config[:port]}" if config[:port].present?
      cmd << "--username=#{config[:username]}" if config[:username].present?
      cmd << config[:database]
      ok = system(env, *cmd, out: File::NULL, err: File::NULL)
      ok && File.exist?(path) && !File.empty?(path) ? path : nil
    end

    def restore_rollback!(path, config, env)
      return if path.nil? || !File.exist?(path)

      cmd = [
        'pg_restore',
        '--clean',
        '--if-exists',
        '--no-owner',
        '--single-transaction',
        "--host=#{config[:host]}",
        "--port=#{config[:port]}",
        "--username=#{config[:username]}",
        "--dbname=#{config[:database]}",
        path.to_s
      ]
      system(env, *cmd, out: File::NULL, err: File::NULL)
    end

    def verify_post_restore!
      # Touch each core table so a corrupt import fails here, not later.
      %w[
        ShopifyProduct
        ShopifyVariant
        SquareItem
        SquareVariation
        SkuLink
        ReconcileRun
        InventoryLevel
        StockAlert
        SyncRun
        LedgerEntry
      ].each do |table|
        ActiveRecord::Base.connection.execute("SELECT COUNT(*) FROM \"#{table}\"")
      end
    rescue StandardError => e
      raise RestoreError, "Restored database failed validation: #{e.message}"
    end
  end
end
