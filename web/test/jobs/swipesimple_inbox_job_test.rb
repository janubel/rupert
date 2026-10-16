# frozen_string_literal: true

require 'test_helper'
require 'tmpdir'

class SwipesimpleInboxJobTest < ActiveSupport::TestCase
  setup do
    @old_directory = ENV['RUPERT_SWIPESIMPLE_INBOX']
    @directory = Dir.mktmpdir('swipesimple-test')
    ENV['RUPERT_SWIPESIMPLE_INBOX'] = @directory
    @csv = File.read(Rails.root.join('test/fixtures/files/swipesimple_transactions.csv'))
    @manifest = { tenant_id: tenants(:default_tenant).id, kind: 'transactions', merchant_account: 'Example Wholesale',
      currency: 'USD', source_timezone: 'America/New_York', exported_at: '2026-10-15T22:00:00-04:00',
      csv: 'source.csv', sha256: Digest::SHA256.hexdigest(@csv.b) }
    travel_to Time.iso8601('2026-10-16T03:00:00Z')
  end

  teardown do
    ENV['RUPERT_SWIPESIMPLE_INBOX'] = @old_directory
    FileUtils.remove_entry(@directory)
    travel_back
    Current.reset
  end

  test 'hourly intake is disabled by default and processes trusted files once without vendor calls' do
    ENV.delete('RUPERT_SWIPESIMPLE_INBOX')
    assert_equal 'disabled', SwipesimpleInboxJob.new.perform[:status]
    ENV['RUPERT_SWIPESIMPLE_INBOX'] = @directory
    write_manifest
    File.write(File.join(@directory, 'source.csv'), @csv)
    assert_equal 1, SwipesimpleInboxJob.new.perform[:imported]
    assert File.exist?(File.join(@directory, 'source.imported.json'))
    assert_equal 0, SwipesimpleInboxJob.new.perform[:imported]
    write_manifest
    assert_no_difference 'SwipesimpleExport.unscoped.count' do
      assert_equal 1, SwipesimpleInboxJob.new.perform[:imported]
    end
    assert_nil Current.tenant
  end

  test 'tampered files traversal symlinks and missing tenants cannot import' do
    File.write(File.join(@directory, 'source.csv'), @csv)
    [{ sha256: '0' * 64 }, { csv: '../secret.csv' }, { tenant_id: 'missing' }].each do |change|
      write_manifest(change)
      assert_no_difference 'SwipesimpleExport.unscoped.count' do
        error = assert_raises(SwipesimpleReportImporter::Error) { SwipesimpleInboxJob.new.perform }
        refute_includes error.message, 'secret.csv'
      end
    end
    write_manifest(csv: 'link.csv')
    File.symlink(File.join(@directory, 'source.csv'), File.join(@directory, 'link.csv'))
    assert_raises(SwipesimpleReportImporter::Error) { SwipesimpleInboxJob.new.perform }
    assert File.exist?(File.join(@directory, 'source.ready.json'))
  end

  private

  def write_manifest(changes = {})
    File.write(File.join(@directory, 'source.ready.json'), JSON.generate(@manifest.merge(changes)))
  end
end
