# frozen_string_literal: true

require 'test_helper'
require 'open3'
require 'tmpdir'
require 'fileutils'

class EmployeeDefaultMigrationTest < ActiveSupport::TestCase
  test 'real SQLite migration and rollback preserve cascading account dependents' do
    Dir.mktmpdir('employee-default-migration') do |directory|
      FileUtils.cp(Rails.root.join('db/migrate/20261017120000_default_users_to_employee.rb'), directory)
      script = <<~'SCRIPT'
        require 'active_record'
        require 'sqlite3'
        ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: File.join(ARGV[0], 'migration.sqlite3'))
        ActiveRecord::Schema.define do
          create_table(:users) { |t| t.string :role, default: 'admin'; t.string :password_digest }
          create_table(:google_login_identities) { |t| t.references :user, null: false, foreign_key: { on_delete: :cascade }; t.string :email }
          create_table(:user_permissions) { |t| t.references :user, null: false, foreign_key: { on_delete: :cascade }; t.string :permission }
        end
        connection = ActiveRecord::Base.connection
        connection.execute("INSERT INTO users (id, role, password_digest) VALUES (1, 'admin', 'unchanged-digest')")
        connection.execute("INSERT INTO google_login_identities (user_id, email) VALUES (1, 'linked@example.invalid')")
        connection.execute("INSERT INTO user_permissions (user_id, permission) VALUES (1, 'reports.read')")
        tables = %w[users google_login_identities user_permissions]
        original = tables.to_h { |table| [table, connection.select_all("SELECT * FROM #{table}").to_a] }
        context = ActiveRecord::MigrationContext.new([ARGV[0]])
        context.up
        raise 'Default did not become employee' unless connection.columns(:users).find { |column| column.name == 'role' }.default == 'employee'
        tables.each { |table| raise "Lost #{table} during migration" unless connection.select_all("SELECT * FROM #{table}").to_a == original.fetch(table) }
        raise 'Foreign keys disabled after migration' unless connection.select_value('PRAGMA foreign_keys') == 1
        raise 'Foreign key damage' unless connection.select_all('PRAGMA foreign_key_check').empty?
        context.down(0)
        raise 'Rollback default incorrect' unless connection.columns(:users).find { |column| column.name == 'role' }.default == 'admin'
        tables.each { |table| raise "Lost #{table} during rollback" unless connection.select_all("SELECT * FROM #{table}").to_a == original.fetch(table) }
        raise 'Foreign keys disabled after rollback' unless connection.select_value('PRAGMA foreign_keys') == 1
        puts 'account_dependents_preserved_in_real_migration_and_rollback'
      SCRIPT
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, '-e', script, directory)
      assert status.success?, "#{stdout}\n#{stderr}"
      assert_includes stdout, 'account_dependents_preserved_in_real_migration_and_rollback'
    end
  end
end
