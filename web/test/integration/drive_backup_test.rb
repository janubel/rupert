# frozen_string_literal: true

require 'test_helper'

class DriveBackupTest < ActionDispatch::IntegrationTest
  setup do
    ShopifyAPI::Context.setup(
      api_key: 'test-key',
      api_secret_key: 'test-secret',
      api_version: ShopifyAPI::AdminVersions::SUPPORTED_ADMIN_VERSIONS.first,
      host_name: 'localhost',
      scope: 'read_products',
      is_private: false,
      is_embedded: false
    )
    Shop.create!(shopify_domain: 'm11u0i-sb.myshopify.com', shopify_token: 'test-token')
    host! 'testshop.example.com' # super_admin resolves the tenant via subdomain
    User.create!(email: 'root@example.com', password: 'password123', role: 'super_admin',
      tenant_id: tenants(:default_tenant).id, name: 'Root')
    post login_path, params: { email: 'root@example.com', password: 'password123' }
    Current.tenant = tenants(:default_tenant)
    EnvStore.platform_set('GOOGLE_DRIVE_CLIENT_ID', 'client-id')
    EnvStore.platform_set('GOOGLE_DRIVE_CLIENT_SECRET', 'client-secret')
  end

  teardown do
    Current.tenant = nil
    EnvStore.platform_set('GOOGLE_DRIVE_CLIENT_ID', nil)
    EnvStore.platform_set('GOOGLE_DRIVE_CLIENT_SECRET', nil)
    EnvStore.platform_set('GOOGLE_DRIVE_REFRESH_TOKEN', nil)
  end

  test 'drive_status reports configuration' do
    get drive_status_settings_path
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal true, body['configured']
    assert_equal false, body['connected']
  end

  test 'drive_backup returns 422 when not connected' do
    post drive_backup_settings_path
    assert_response :unprocessable_entity
    assert_equal false, JSON.parse(response.body)['ok']
  end

  test 'drive_backup runs and returns a success link' do
    EnvStore.platform_set('GOOGLE_DRIVE_REFRESH_TOKEN', 'refresh-token')
    log = BackupLog.create!(
      status: 'success',
      startedAt: Time.current,
      fileName: 'x.dump',
      driveUrl: 'https://drive.google.com/file/d/FILE1/view',
      tenant_id: Current.tenant_id
    )
    GoogleDriveBackupService.stubs(:backup!).returns(log)

    post drive_backup_settings_path
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal 'success', body['status']
    assert_includes body['driveUrl'], 'FILE1'
  end

  test 'drive_auth redirects to Google when not configured' do
    EnvStore.platform_set('GOOGLE_DRIVE_CLIENT_ID', nil)
    get drive_auth_settings_path
    assert_redirected_to settings_path
    follow_redirect!
    assert_response :success
    assert_match(/GOOGLE_DRIVE_CLIENT_ID/, response.body)
  end
  def begin_drive_consent
    get drive_auth_settings_path
    assert_response :redirect
    query = URI.decode_www_form(URI(response.location).query).to_h
    assert_equal google_callback_url, query['redirect_uri']
    assert query['state'].start_with?('drive:')
    query['state']
  end

  test 'registered callback completes backup consent without logging in or provisioning users' do
    state = begin_drive_consent
    GoogleOauthService.expects(:exchange_code!).never
    GoogleDriveBackupService.expects(:exchange_code!).with('drive-code', redirect_uri: google_callback_url)
    assert_no_difference 'User.count' do
      get google_callback_path, params: { state: state, code: 'drive-code' }
    end
    assert_redirected_to settings_path
    assert_equal 'Connected to Google Drive.', flash[:notice]
    GoogleDriveBackupService.expects(:exchange_code!).never
    get google_callback_path, params: { state: state, code: 'drive-code' }
    assert_match(/state check/, flash[:alert])
  end

  test 'backup callback rejects tampering, expiry and revoked platform access' do
    state = begin_drive_consent
    GoogleDriveBackupService.expects(:exchange_code!).never
    get google_callback_path, params: { state: state + 'x', code: 'bad' }
    assert_match(/state check/, flash[:alert])
    state = begin_drive_consent
    travel 11.minutes do
      get google_callback_path, params: { state: state, code: 'expired' }
      assert_match(/state check/, flash[:alert])
    end
    state = begin_drive_consent
    User.find_by!(email: 'root@example.com').update!(active: false)
    get google_callback_path, params: { state: state, code: 'revoked' }
    assert_redirected_to login_path
  end

  test 'declined backup consent cannot exchange a code' do
    state = begin_drive_consent
    GoogleDriveBackupService.expects(:exchange_code!).never
    get google_callback_path, params: { state: state, error: 'access_denied' }
    assert_redirected_to settings_path
    assert_match(/declined/, flash[:alert])
  end
end
