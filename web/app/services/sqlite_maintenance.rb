# frozen_string_literal: true

# Local database operations only. No remote commerce APIs are called.
class SqliteMaintenance
  class << self
    def report
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        return { adapter: connection.adapter_name, supported: false } unless sqlite?(connection)

        pragmas = %w[journal_mode synchronous busy_timeout page_count page_size freelist_count wal_autocheckpoint]
        report = pragmas.to_h { |key| [key.to_sym, connection.select_value("PRAGMA #{key}")] }
        path = connection.pool.db_config.database.to_s
        path = Rails.root.join(path).to_s unless path.start_with?('/') || path == ':memory:'
        report.merge(
          adapter: connection.adapter_name,
          supported: true,
          sqlite_version: connection.select_value('SELECT sqlite_version()'),
          # Rails installs a Ruby busy handler, which can leave the native
          # PRAGMA at zero. Report the configured handler timeout separately.
          configured_timeout_ms: connection.pool.db_config.configuration_hash[:timeout].to_i,
          database_bytes: report[:page_count].to_i * report[:page_size].to_i,
          wal_bytes: File.file?("#{path}-wal") ? File.size("#{path}-wal") : 0,
          free_bytes: report[:freelist_count].to_i * report[:page_size].to_i
        )
      end
    end

    # SQLite bounds modern PRAGMA optimize automatically. The mask also
    # considers tables not yet queried by this short-lived maintenance process.
    def optimize!
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        return false unless sqlite?(connection)

        connection.execute('PRAGMA optimize=0x10002')
        true
      end
    end

    private

    def sqlite?(connection)
      connection.adapter_name.downcase.include?('sqlite')
    end
  end
end
