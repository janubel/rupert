# frozen_string_literal: true

require 'tmpdir'

raise 'Fresh migration verification is test-only' unless Rails.env.test?
original_config = ActiveRecord::Base.connection_db_config.configuration_hash
raise 'SQLite is required' unless original_config[:adapter] == 'sqlite3'
original_verbose = ActiveRecord::Migration.verbose

begin
  Dir.mktmpdir('rupert-fresh-sqlite-') do |directory|
    ActiveRecord::Base.establish_connection(original_config.merge(database: File.join(directory, 'fresh.sqlite3')))
    ActiveRecord::Migration.verbose = false
    context = ActiveRecord::MigrationContext.new(Rails.root.join('db/migrate').to_s)
    context.migrate
    connection = ActiveRecord::Base.connection
    raise 'Migrations remain pending' if context.needs_migration?
    raise 'SQLite integrity check failed' unless connection.select_value('PRAGMA integrity_check') == 'ok'
    raise 'Foreign key violations' unless connection.select_all('PRAGMA foreign_key_check').empty?
    raise 'Checkout display foreign key missing' unless connection.foreign_keys(:pos_checkouts).any? { |key| key.to_table == 'pos_display_sessions' }
    raise 'FTS index missing' unless connection.select_value("SELECT name FROM sqlite_master WHERE name = 'rupert_orders_fts'")

    puts "FRESH_SQLITE_MIGRATIONS_VERIFIED (#{context.migrations.length} migrations)"
    ActiveRecord::Base.connection_pool.disconnect!
  end
ensure
  ActiveRecord::Migration.verbose = original_verbose
  ActiveRecord::Base.establish_connection(original_config)
end
