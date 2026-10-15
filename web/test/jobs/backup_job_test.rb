# frozen_string_literal: true

require 'test_helper'

class BackupJobTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
    EnvStore::PLATFORM_KEYS.each { |key| EnvStore.platform_set(key, nil) }
  end

  teardown { Current.reset }

  test 'legacy tenant-owned credentials never authorize a snapshot or scheduled upload' do
    EnvStore.set('GOOGLE_DRIVE_CLIENT_ID', 'tenant-client')
    EnvStore.set('GOOGLE_DRIVE_CLIENT_SECRET', 'tenant-secret')
    EnvStore.set('GOOGLE_DRIVE_REFRESH_TOKEN', 'tenant-token')
    EnvStore.set('GOOGLE_DRIVE_FOLDER_ID', 'tenant-folder')
    refute GoogleDriveBackupService.configured?
    refute GoogleDriveBackupService.connected?
    BackupService.expects(:snapshot_path).never
    assert_raises(GoogleDriveBackupService::NotConnectedError) { GoogleDriveBackupService.backup! }
    BackupJob.perform_now
  end

  test 'scheduler uses the platform destination once regardless of connected tenant rows' do
    EnvStore.platform_set('GOOGLE_DRIVE_CLIENT_ID', 'platform-client')
    EnvStore.platform_set('GOOGLE_DRIVE_CLIENT_SECRET', 'platform-secret')
    EnvStore.platform_set('GOOGLE_DRIVE_REFRESH_TOKEN', 'platform-token')
    other = Tenant.create!(name: 'Other', subdomain: 'other-drive-job')
    [Current.tenant_id, other.id].each do |tenant_id|
      Setting.create!(tenant_id: tenant_id, key: 'GOOGLE_DRIVE_REFRESH_TOKEN', value: 'tenant-token')
    end
    GoogleDriveBackupService.expects(:backup!).once.with do |arguments|
      arguments == { actor: 'scheduler' } && Current.tenant.nil? && Current.user.nil?
    end.returns(nil)
    BackupJob.perform_now
    assert_nil Current.tenant
  end

  test 'disconnect disables host-provided refresh token instead of falling back to it' do
    EnvStore.platform_set('GOOGLE_DRIVE_CLIENT_ID', 'platform-client')
    EnvStore.platform_set('GOOGLE_DRIVE_CLIENT_SECRET', 'platform-secret')
    ENV.stubs(:fetch).with('GOOGLE_DRIVE_REFRESH_TOKEN', '').returns('host-token')
    assert GoogleDriveBackupService.connected?
    GoogleDriveBackupService.disconnect!
    refute GoogleDriveBackupService.connected?
    assert_equal '', Setting.find_by!(tenant_id: nil, key: 'GOOGLE_DRIVE_REFRESH_TOKEN').value
  end
end
