# frozen_string_literal: true

require 'test_helper'
require 'sqlite3'

class BackupServiceTest < ActiveSupport::TestCase
  test 'restore refuses before changing the supplied snapshot' do
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'synthetic.sqlite3')
      File.binwrite(path, 'synthetic SQLite snapshot')
      error = assert_raises(BackupService::RestoreError) { BackupService.restore!(path) }
      assert_match(/offline maintenance/, error.message)
      assert_equal 'synthetic SQLite snapshot', File.binread(path)
    end
  end

  test 'snapshots in the same second use distinct private files and retain committed WAL data' do
    Dir.mktmpdir do |dir|
      db = SQLite3::Database.new(File.join(dir, 'source.sqlite3'))
      db.execute('PRAGMA journal_mode=WAL')
      db.execute('PRAGMA wal_autocheckpoint=0')
      db.execute('CREATE TABLE recovery_rows (id INTEGER PRIMARY KEY)')
      db.execute('INSERT INTO recovery_rows VALUES (1)')
      connection = Object.new
      connection.define_singleton_method(:quote) { |value| "'#{value.gsub("'", "''")}'" }
      connection.define_singleton_method(:execute) { |sql| db.execute(sql) }
      Time.stub(:now, Time.at(1_800_000_000)) do
        ActiveRecord::Base.stub(:connection, connection) do
          first = BackupService.send(:sqlite_snapshot_path, Pathname.new(dir))
          db.execute('INSERT INTO recovery_rows VALUES (2)')
          second = BackupService.send(:sqlite_snapshot_path, Pathname.new(dir))
          refute_equal first, second
          [first, second].zip([1, 2]).each do |path, expected_rows|
            snapshot = SQLite3::Database.new(path.to_s)
            assert_equal expected_rows, snapshot.get_first_value('SELECT count(*) FROM recovery_rows')
            assert_equal 'ok', snapshot.get_first_value('PRAGMA integrity_check')
            assert_equal 0o600, File.stat(path).mode & 0o777
            snapshot.close
          end
        end
      end
    ensure
      db&.close
    end
  end
end
