# frozen_string_literal: true

require 'test_helper'

class SqliteMaintenanceTest < ActiveSupport::TestCase
  test 'diagnostics and optimization respect the active adapter and preserve business rows' do
    before = User.order(:id).pluck(:id, :email, :role)
    report = SqliteMaintenance.report

    if SearchSql.sqlite?
      assert report[:supported]
      assert_match(/\A\d+\.\d+\.\d+/, report[:sqlite_version])
      assert_equal 'wal', report[:journal_mode]
      assert_equal 5000, report[:configured_timeout_ms]
      assert report[:database_bytes].positive?
      assert report[:wal_bytes] >= 0
      assert SqliteMaintenance.optimize!
    else
      refute report[:supported]
      refute SqliteMaintenance.optimize!
    end

    assert_equal before, User.order(:id).pluck(:id, :email, :role)
    refute_includes report.keys, :database_path
  end
end
