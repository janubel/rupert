# frozen_string_literal: true

require 'test_helper'

class DrivePlatformAccessTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = tenants(:default_tenant)
    @user = users(:regular_user)
    Current.tenant = @tenant
    post login_path, params: { email: @user.email, password: 'password' }
  end

  teardown { Current.reset }

  test 'store administrators cannot configure or inspect full-instance Drive backups' do
    GoogleDriveBackupService.expects(:auth_url).never
    GoogleDriveBackupService.expects(:exchange_code!).never
    GoogleDriveBackupService.expects(:disconnect!).never
    GoogleDriveBackupService.expects(:backup!).never
    [drive_status_settings_path, drive_logs_settings_path, drive_auth_settings_path,
     drive_oauth_callback_settings_path].each do |path|
      get path, params: { state: 'untrusted', code: 'untrusted' }
      assert_redirected_to settings_path
    end
    [drive_disconnect_settings_path, drive_backup_settings_path].each do |path|
      post path
      assert_redirected_to settings_path
    end
    get settings_path
    assert_response :success
    assert_select '#drive-setup', count: 0
    get env_settings_path
    assert_response :success
    refute response.parsed_body['keys'].any? { |row| row['key'].start_with?('GOOGLE_DRIVE_') }
  end

  test 'store imports and previews reject every Drive key without partial mutation' do
    EnvStore.set('SQUARE_ENVIRONMENT', 'production')
    EnvStore::PLATFORM_KEYS.each do |key|
      text = "SQUARE_ENVIRONMENT=sandbox\n#{key}=untrusted\n"
      assert_no_difference('Setting.count') { post env_import_settings_path, params: { text: text } }
      assert_response :unprocessable_entity
      assert_match(/platform super administrator/, response.parsed_body['error'])
      assert_equal 'production', Setting.find_by!(tenant_id: @tenant.id, key: 'SQUARE_ENVIRONMENT').value
      assert_no_difference('Setting.count') { post env_preview_settings_path, params: { text: text } }
      assert_response :unprocessable_entity
    end
  end

  test 'platform import puts Drive keys in platform scope and business keys in the selected workspace' do
    @user.update!(role: 'super_admin')
    post env_import_settings_path, params: { text: "GOOGLE_DRIVE_CLIENT_ID=approved-id\nGOOGLE_DRIVE_REFRESH_TOKEN=approved-token\nSQUARE_ENVIRONMENT=sandbox\n" }
    assert_response :success
    assert_equal 'approved-id', Setting.find_by!(tenant_id: nil, key: 'GOOGLE_DRIVE_CLIENT_ID').value
    assert_equal 'approved-token', Setting.find_by!(tenant_id: nil, key: 'GOOGLE_DRIVE_REFRESH_TOKEN').value
    assert_equal 'sandbox', Setting.find_by!(tenant_id: @tenant.id, key: 'SQUARE_ENVIRONMENT').value
    assert_nil Setting.find_by(tenant_id: @tenant.id, key: 'GOOGLE_DRIVE_REFRESH_TOKEN')
  end

  test 'platform previews and exports use global values and ignore legacy tenant settings' do
    @user.update!(role: 'super_admin')
    Setting.create!(tenant_id: @tenant.id, key: 'GOOGLE_DRIVE_CLIENT_ID', value: 'untrusted-tenant-id')
    post env_preview_settings_path, params: { text: 'GOOGLE_DRIVE_CLIENT_ID=replacement' }
    assert_response :success
    assert_equal false, response.parsed_body['keys'].first['currently_set']
    EnvStore.platform_set('GOOGLE_DRIVE_CLIENT_ID', 'approved-platform-id')
    post env_preview_settings_path, params: { text: 'GOOGLE_DRIVE_CLIENT_ID=replacement' }
    assert_response :success
    assert_equal true, response.parsed_body['keys'].first['currently_set']
    assert_equal false, response.parsed_body['keys'].first['from_env_file']
    post env_export_settings_path, params: { password: 'password' }
    assert_response :success
    assert_includes response.body, 'GOOGLE_DRIVE_CLIENT_ID=approved-platform-id'
    refute_includes response.body, 'untrusted-tenant-id'
  end

  test 'Google consent state cannot be transferred to a different selected workspace' do
    @user.update!(role: 'super_admin')
    GoogleDriveBackupService.stubs(:auth_url).returns('https://accounts.google.com/consent')
    GoogleDriveBackupService.expects(:exchange_code!).never
    get drive_auth_settings_path
    assert_redirected_to 'https://accounts.google.com/consent'
    state = session[:drive_oauth_state]
    other = Tenant.create!(name: 'Other', subdomain: 'other-drive')
    @user.update!(tenant: other)
    get drive_oauth_callback_settings_path, params: { state: state, code: 'code' }
    assert_redirected_to settings_path
    assert_match(/state check/, flash[:alert])
    assert_nil session[:drive_oauth_state]
  end

  test 'Google consent state cannot be transferred to another platform operator' do
    @user.update!(role: 'super_admin')
    GoogleDriveBackupService.stubs(:auth_url).returns('https://accounts.google.com/consent')
    GoogleDriveBackupService.expects(:exchange_code!).never
    get drive_auth_settings_path
    state = session[:drive_oauth_state]
    other = User.create!(tenant: @tenant, email: 'other-drive-operator@example.com', password: 'password123', role: 'super_admin')
    post login_path, params: { email: other.email, password: 'password123' }
    get drive_oauth_callback_settings_path, params: { state: state, code: 'code' }
    assert_redirected_to settings_path
    assert_match(/state check/, flash[:alert])
  end
end
