# frozen_string_literal: true

require 'test_helper'
require 'fileutils'
require 'open3'
require 'tmpdir'

class PrepareSqliteTest < ActiveSupport::TestCase
  setup do
    @app_root = Dir.mktmpdir('prepare-sqlite-test')
    FileUtils.mkdir_p(File.join(@app_root, 'bin'))
    FileUtils.mkdir_p(File.join(@app_root, 'storage'))
    @script = File.join(@app_root, 'bin', 'prepare-sqlite')
    FileUtils.cp(Rails.root.join('bin', 'prepare-sqlite'), @script)
    FileUtils.chmod(0o755, @script)
    @rails_called = File.join(@app_root, 'rails-called')
    File.write(File.join(@app_root, 'bin', 'rails'), <<~'SH')
      #!/bin/sh
      printf '%s\n' "$*" > "$PREPARE_SQLITE_RAILS_CALLED"
    SH
    FileUtils.chmod(0o755, File.join(@app_root, 'bin', 'rails'))
  end

  teardown do
    FileUtils.remove_entry(@app_root) if @app_root && File.exist?(@app_root)
  end

  test 'accepts an existing SQLite production file and runs db prepare' do
    database = File.join(@app_root, 'storage', 'production.sqlite3')
    File.binwrite(database, "SQLite format 3\0synthetic database")

    _stdout, stderr, status = run_preflight('storage/production.sqlite3')

    assert status.success?, stderr
    assert_equal "db:prepare\n", File.read(@rails_called)
  end

  test 'rejects missing, empty, and non-SQLite production files without running Rails' do
    missing = File.join(@app_root, 'storage', 'missing.sqlite3')
    assert_preflight_rejected(missing)

    empty = File.join(@app_root, 'storage', 'empty.sqlite3')
    File.write(empty, '')
    assert_preflight_rejected(empty)

    non_sqlite = File.join(@app_root, 'storage', 'not-sqlite.sqlite3')
    File.write(non_sqlite, 'synthetic non-SQLite file')
    assert_preflight_rejected(non_sqlite)
  end

  test 'explicit fresh-install opt-in runs db prepare when no database exists' do
    database = File.join(@app_root, 'storage', 'fresh.sqlite3')

    _stdout, stderr, status = run_preflight(database, initialize_database: '1')

    assert status.success?, stderr
    assert_equal "db:prepare\n", File.read(@rails_called)
    refute File.exist?(database), 'the stub Rails executable must not create a database'
  end

  private

  def run_preflight(database, initialize_database: nil)
    env = {
      'RUPERT_SQLITE_DATABASE_PRODUCTION' => database,
      'RUPERT_INITIALIZE_DATABASE' => initialize_database,
      'PREPARE_SQLITE_RAILS_CALLED' => @rails_called
    }
    Open3.capture3(env, @script, chdir: @app_root)
  end

  def assert_preflight_rejected(database)
    FileUtils.rm_f(@rails_called)
    _stdout, stderr, status = run_preflight(database)

    refute status.success?, "expected preflight to reject #{database}"
    assert_match(/verified SQLite database copy/, stderr)
    assert_match(/RUPERT_INITIALIZE_DATABASE=1/, stderr)
    refute File.exist?(@rails_called), 'Rails must not run for an unverified production database'
  end
end
