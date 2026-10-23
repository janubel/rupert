# frozen_string_literal: true

require 'test_helper'

class GoogleDriveBackupServiceTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
    EnvStore.platform_set('GOOGLE_DRIVE_CLIENT_ID', 'client-id')
    EnvStore.platform_set('GOOGLE_DRIVE_CLIENT_SECRET', 'client-secret')
    EnvStore.platform_set('GOOGLE_DRIVE_REFRESH_TOKEN', 'refresh-token')
    EnvStore.platform_set('GOOGLE_DRIVE_FOLDER_ID', nil)

    @snapshot = Rails.root.join('tmp', 'backups', "test-snapshot-#{SecureRandom.hex(8)}.dump")
    FileUtils.mkdir_p(@snapshot.dirname)
    File.write(@snapshot, 'PGDMP test backup')
    BackupService.stubs(:snapshot_path).returns(@snapshot)
  end

  teardown do
    Current.tenant = nil
    FileUtils.rm_f(@snapshot)
    EnvStore.platform_set('GOOGLE_DRIVE_CLIENT_ID', nil)
    EnvStore.platform_set('GOOGLE_DRIVE_CLIENT_SECRET', nil)
    EnvStore.platform_set('GOOGLE_DRIVE_REFRESH_TOKEN', nil)
    EnvStore.platform_set('GOOGLE_DRIVE_ALLOWED_DOMAIN', nil)
    EnvStore.platform_set('GOOGLE_DRIVE_ACCOUNT_EMAIL', nil)
  end

  test 'configured? and connected? reflect stored credentials' do
    assert GoogleDriveBackupService.configured?
    assert GoogleDriveBackupService.connected?

    EnvStore.platform_set('GOOGLE_DRIVE_REFRESH_TOKEN', nil)
    refute GoogleDriveBackupService.connected?
    assert GoogleDriveBackupService.configured?
  end

  test 'auth_url builds a consent URL with offline access and state' do
    url = GoogleDriveBackupService.auth_url(
      redirect_uri: 'https://x/settings/drive_oauth_callback', state: 'abc123'
    )
    assert_includes url, 'accounts.google.com/o/oauth2/auth'
    assert_includes url, 'access_type=offline'
    assert_includes url, 'prompt=consent'
    assert_includes url, 'state=abc123'
    assert_includes url, 'scope=https://www.googleapis.com/auth/drive.file'
  end

  test 'Google consent uses platform credentials despite legacy tenant credentials' do
    EnvStore.set('GOOGLE_DRIVE_CLIENT_ID', 'untrusted-tenant-id')
    EnvStore.set('GOOGLE_DRIVE_CLIENT_SECRET', 'untrusted-tenant-secret')
    url = GoogleDriveBackupService.auth_url(redirect_uri: 'https://x/cb')
    assert_includes url, 'client_id=client-id'
    refute_includes url, 'untrusted-tenant'
  end

  test 'auth_url raises when credentials are missing' do
    EnvStore.platform_set('GOOGLE_DRIVE_CLIENT_ID', nil)
    assert_raises(GoogleDriveBackupService::NotConfiguredError) do
      GoogleDriveBackupService.auth_url(redirect_uri: 'https://x/cb')
    end
  end

  test 'backup! uploads a snapshot without a public link and records a success log' do
    drive = Object.new
    created = Struct.new(:id).new('FILE1')
    drive.stubs(:create_file).returns(created)
    drive.stubs(:create_permission).raises('public permission must not be created')
    drive.stubs(:list_files).returns(Struct.new(:files).new([]))

    GoogleDriveBackupService.stubs(:drive_service).returns(drive)
    GoogleDriveBackupService.stubs(:ensure_folder!).returns('FOLDER1')
    GoogleDriveBackupService.stubs(:prune_old!).returns(nil)

    bytes = File.binread(@snapshot)
    drive.define_singleton_method(:get_file) do |_id, **opts|
      if opts[:download_dest]
        File.binwrite(opts[:download_dest], bytes)
      else
        Struct.new(:size, :md5_checksum).new(bytes.bytesize, Digest::MD5.hexdigest(bytes))
      end
    end
    expected_size = File.size(@snapshot)
    log = GoogleDriveBackupService.backup!(actor: 'test')

    assert log.success?
    assert_nil log.tenant_id
    assert_equal tenants(:default_tenant), Current.tenant
    assert_equal 'success', log.status
    assert_equal 'FILE1', log.driveFileId
    assert_includes log.driveUrl, 'FILE1'
    assert_match(/rupert-backup-\d{8}-\d{6}\.dump/, log.fileName)
    assert_equal expected_size, log.fileSize
    refute File.exist?(@snapshot), 'snapshot temp file should be cleaned up'
  end

  test 'backup! records a failed log and re-raises' do
    drive = Object.new
    drive.stubs(:create_file).raises(StandardError, 'upload exploded')

    GoogleDriveBackupService.stubs(:drive_service).returns(drive)
    GoogleDriveBackupService.stubs(:ensure_folder!).returns('FOLDER1')

    assert_raises(StandardError) { GoogleDriveBackupService.backup!(actor: 'test') }

    log = BackupLog.unscoped.where(tenant_id: nil).order(startedAt: :desc).first
    assert_equal 'failed', log.status
    assert_includes log.error, 'upload exploded'
  end

  test 'backup! raises NotConnected when no refresh token is stored' do
    EnvStore.platform_set('GOOGLE_DRIVE_REFRESH_TOKEN', nil)
    assert_raises(GoogleDriveBackupService::NotConnectedError) do
      GoogleDriveBackupService.backup!
    end
  end

  test 'retention defaults to 7 and respects the setting' do
    assert_equal 7, GoogleDriveBackupService.retention
    EnvStore.platform_set('GOOGLE_DRIVE_RETENTION', '14')
    assert_equal 14, GoogleDriveBackupService.retention
  ensure
    EnvStore.platform_set('GOOGLE_DRIVE_RETENTION', nil)
  end
  test 'corrupt downloaded backup fails before pruning and never reports success' do
    drive = Object.new
    drive.expects(:create_file).returns(Struct.new(:id).new('FILE1'))
    bytes = File.binread(@snapshot)
    drive.define_singleton_method(:get_file) do |_id, **opts|
      if opts[:download_dest]
        File.binwrite(opts[:download_dest], 'corrupt')
      else
        Struct.new(:size, :md5_checksum).new(bytes.bytesize, Digest::MD5.hexdigest(bytes))
      end
    end
    GoogleDriveBackupService.stubs(:drive_service).returns(drive)
    GoogleDriveBackupService.stubs(:ensure_folder!).returns('FOLDER1')
    GoogleDriveBackupService.expects(:prune_old!).never
    assert_raises(GoogleDriveBackupService::NotConnectedError) { GoogleDriveBackupService.backup! }
    assert_equal 'failed', BackupLog.unscoped.where(tenant_id: nil).order(startedAt: :desc).first.status
    refute File.exist?(@snapshot)
  end

  test 'allowed domain is normalised and validated' do
    GoogleDriveBackupService.allowed_domain = '  @HerbalHealersCBD.com '
    assert_equal 'herbalhealerscbd.com', GoogleDriveBackupService.allowed_domain
    assert_raises(ArgumentError) { GoogleDriveBackupService.allowed_domain = 'not a domain' }
    GoogleDriveBackupService.allowed_domain = ''
    assert_equal '', GoogleDriveBackupService.allowed_domain
  end

  test 'auth_url pre-selects the allowed domain' do
    GoogleDriveBackupService.allowed_domain = 'example.com'
    url = GoogleDriveBackupService.auth_url(redirect_uri: 'https://x/cb', state: 's')
    assert_includes url, 'hd=example.com'
  end

  test 'connecting an account outside the allowed domain stores nothing and revokes the token' do
    GoogleDriveBackupService.allowed_domain = 'example.com'
    EnvStore.platform_set('GOOGLE_DRIVE_REFRESH_TOKEN', nil)
    Signet::OAuth2::Client.any_instance.stubs(:fetch_access_token!).returns(true)
    Signet::OAuth2::Client.any_instance.stubs(:refresh_token).returns('new-refresh')
    GoogleDriveBackupService.stubs(:account_email_for).returns('someone@gmail.com')
    GoogleDriveBackupService.expects(:revoke).with('new-refresh').once
    error = assert_raises(GoogleDriveBackupService::DomainNotAllowedError) do
      GoogleDriveBackupService.exchange_code!('code', redirect_uri: 'https://x/cb')
    end
    assert_includes error.message, 'example.com'
    refute GoogleDriveBackupService.connected?
    assert_equal '', GoogleDriveBackupService.account_email
  end

  test 'connecting an account inside the allowed domain records the account' do
    GoogleDriveBackupService.allowed_domain = 'example.com'
    Signet::OAuth2::Client.any_instance.stubs(:fetch_access_token!).returns(true)
    Signet::OAuth2::Client.any_instance.stubs(:refresh_token).returns('new-refresh')
    GoogleDriveBackupService.stubs(:account_email_for).returns('backups@example.com')
    GoogleDriveBackupService.expects(:revoke).never
    GoogleDriveBackupService.exchange_code!('code', redirect_uri: 'https://x/cb')
    assert_equal 'backups@example.com', GoogleDriveBackupService.account_email
    refute GoogleDriveBackupService.wrong_account?
  end

  test 'a connection outside a newly set domain is the wrong account and cannot back up' do
    EnvStore.platform_set('GOOGLE_DRIVE_ACCOUNT_EMAIL', 'owner@gmail.com')
    GoogleDriveBackupService.allowed_domain = 'example.com'
    assert GoogleDriveBackupService.wrong_account?
    assert_equal 'Wrong account', SourceSyncStatus.all.find { |source| source[:key] == 'google_backup' }[:badge]
    assert_raises(GoogleDriveBackupService::DomainNotAllowedError) { GoogleDriveBackupService.backup! }
  end

  test 'status badges use one colour rule' do
    assert_equal 'pill-rose', SourceSyncStatus.tone('Needs connection')
    assert_equal 'pill-rose', SourceSyncStatus.tone('Wrong account')
    assert_equal 'pill-fern', SourceSyncStatus.tone('Healthy')
    assert_equal 'pill-clay', SourceSyncStatus.tone('Awaiting backup')
  end
end
