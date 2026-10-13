# frozen_string_literal: true

# Copy a PostgreSQL Rupert database into a fresh SQLite database.
#
#   RUPERT_DB_ADAPTER=sqlite3 SOURCE_DATABASE_URL=postgres://user:pass@host/rupert_production \
#     bin/rails db:postgres_to_sqlite
#
# The target is whatever the sqlite3 entry of config/database.yml points at for the current RAILS_ENV
# (storage/production.sqlite3 by default). The task refuses to run unless that database has the schema loaded
# (`bin/rails db:schema:load`) and is EMPTY, so it can never overwrite data. It only reads from PostgreSQL.
#
# Every table is copied in primary-key order inside one SQLite transaction; row counts are compared per table at
# the end and the transaction rolls back on any mismatch. Solid Queue tables are skipped (transient job state).
# Values are read as text and cast by the SQLite column type, so timestamps stay UTC and ids are preserved.
namespace :db do
  desc 'Copy a PostgreSQL database (SOURCE_DATABASE_URL) into an empty SQLite database'
  task postgres_to_sqlite: :environment do
    require 'pg'

    abort 'Run with RUPERT_DB_ADAPTER=sqlite3 so the target is SQLite.' unless ActiveRecord::Base.connection.adapter_name =~ /sqlite/i
    source_url = ENV['SOURCE_DATABASE_URL'].presence or abort 'Set SOURCE_DATABASE_URL=postgres://user:pass@host/dbname'

    skip = /\A(solid_queue|solid_cache|solid_cable|ar_internal_metadata|schema_migrations)/
    target = ActiveRecord::Base.connection
    tables = target.tables.reject { |t| t.match?(skip) }.sort

    populated = tables.select { |t| target.select_value("SELECT 1 FROM #{target.quote_table_name(t)} LIMIT 1") }
    abort "Target is not empty (#{populated.first(3).join(', ')}…). Refusing to continue." if populated.any?

    source = PG.connect(source_url)
    source.exec("SET TIME ZONE 'UTC'")
    source.exec('SET default_transaction_read_only = on')
    source_tables = source.exec("SELECT tablename FROM pg_tables WHERE schemaname = 'public'").map { |r| r['tablename'] }

    missing = tables - source_tables
    abort "Source is missing tables the app expects: #{missing.join(', ')}" if missing.any?

    counts = {}
    target.execute('PRAGMA foreign_keys = OFF')
    begin
      # The app's Time.zone is not UTC; the text read from PostgreSQL is UTC, so parse it as UTC or every
      # timestamp would shift by the zone offset.
      Time.use_zone('UTC') do
        target.transaction do
          tables.each do |table|
            model = Class.new(ActiveRecord::Base) do
              self.table_name = table
              self.inheritance_column = nil
            end
            columns = model.columns.map(&:name)
            source_columns = source.exec_params(
              "SELECT column_name FROM information_schema.columns WHERE table_schema = 'public' AND table_name = $1", [table]
            ).map { |r| r['column_name'] }
            shared = columns & source_columns
            dropped = source_columns - columns
            warn "  #{table}: ignoring columns not in the SQLite schema: #{dropped.join(', ')}" if dropped.any?

            select = shared.map { |c| %("#{c}"::text AS "#{c}") }.join(', ')
            order = target.primary_key(table) ? %( ORDER BY "#{target.primary_key(table)}") : ''
            copied = 0
            rows = []
            flush = lambda do
              next if rows.empty?

              model.insert_all!(rows)
              copied += rows.length
              rows = []
            end
            source.send_query(%(SELECT #{select} FROM "#{table}"#{order}))
            source.set_single_row_mode
            source.get_result.stream_each do |row|
            rows << row.to_h
            flush.call if rows.length >= 500
          end
            flush.call
            counts[table] = copied
            puts format('  %-34s %8d rows', table, copied)
          end

          tables.each do |table|
            expected = source.exec(%(SELECT COUNT(*) FROM "#{table}")).getvalue(0, 0).to_i
            actual = target.select_value("SELECT COUNT(*) FROM #{target.quote_table_name(table)}").to_i
            raise "Row count mismatch in #{table}: postgres=#{expected} sqlite=#{actual}" unless expected == actual
          end
        end
      end
    ensure
      target.execute('PRAGMA foreign_keys = ON')
      source.close
    end

    # Search indexes are external-content FTS5 tables: they are not filled by a plain row copy.
    SearchSql::SQLITE_FTS.each_key do |fts|
      next unless target.select_value("SELECT 1 FROM sqlite_master WHERE name = #{target.quote(fts)}")

      target.execute("INSERT INTO #{target.quote_table_name(fts)}(#{target.quote_table_name(fts)}) VALUES('rebuild')")
      puts "  rebuilt search index #{fts}"
    end

    violations = target.select_rows('PRAGMA foreign_key_check')
    warn "  #{violations.length} foreign key violation(s) carried over from the source data (first: #{violations.first.inspect})" if violations.any?
    puts "\nCopied #{counts.values.sum} rows across #{counts.length} tables; counts match PostgreSQL."
  end
end
