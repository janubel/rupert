# frozen_string_literal: true

require 'test_helper'

class RetentionDrivesTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    @user = User.create!(tenant: @tenant, email: 'drive-retention@example.com', password: 'password123', role: 'admin', name: 'Owner')
    post login_path, params: { email: @user.email, password: 'password123' }
    Current.tenant = @tenant
    RetentionDrive.stubs(:configured?).returns(true)
    RetentionDrive.stubs(:auth_url).with do |values|
      @state = values[:state]
      values[:redirect_uri].end_with?('/auth/google/callback') && @state.start_with?('retention:')
    end.returns('https://accounts.google.com/consent')
  end
  teardown { Current.reset }

  test 'consent is tenant actor and purpose bound without changing platform backup credentials' do
    get retention_drive_path
    assert_response :success
    assert_select 'a', 'Connect Google Drive'
    get connect_retention_drive_path
    assert_redirected_to 'https://accounts.google.com/consent'
    RetentionDrive.expects(:exchange_code!).with('approved', redirect_uri: 'http://www.example.com/auth/google/callback').once
    assert_enqueued_with(job: RetentionDriveJob, args: [@tenant.id]) do
      get google_callback_path, params: { state: @state, code: 'approved' }
    end
    assert_redirected_to retention_drive_path
    RetentionDrive.expects(:exchange_code!).never
    get google_callback_path, params: { state: @state, code: 'replayed' }
    assert_redirected_to login_path
  end

  test 'wrong expired and declined consent never exchanges credentials' do
    get connect_retention_drive_path
    RetentionDrive.expects(:exchange_code!).never
    get google_callback_path, params: { state: 'retention:wrong', code: 'wrong' }
    assert_redirected_to login_path
    get connect_retention_drive_path
    travel 11.minutes do
      get google_callback_path, params: { state: @state, code: 'expired' }
      assert_redirected_to login_path
    end
    get connect_retention_drive_path
    get google_callback_path, params: { state: @state, error: 'access_denied' }
    assert_redirected_to retention_drive_path
    assert_match(/declined/, flash[:alert])
  end

  test 'report readers cannot connect disconnect or start copies and foreign data stays private' do
    @user.update!(role: 'reporting')
    get retention_drive_path
    assert_response :success
    get connect_retention_drive_path
    assert_redirected_to root_path
    post sync_retention_drive_path
    assert_redirected_to root_path
    post disconnect_retention_drive_path
    assert_redirected_to root_path
    other = Tenant.create!(name: 'Other Drive', subdomain: 'other-drive')
    Current.set(tenant: other) { RetentionDriveConnection.create!(refresh_token: 'private', account_email: 'foreign-private@example.com', generation: 'foreign', enabled: true) }
    get retention_drive_path
    refute_includes response.body, 'foreign-private@example.com'
    refute_includes response.body, 'private-refresh'
  end

  test 'disconnect preserves source originals and previously verified receipts' do
    connection = RetentionDriveConnection.create!(refresh_token: 'private', account_email: 'owner@example.com', generation: 'same-account', enabled: true)
    item = RetentionDriveItem.create!(generation: 'same-account', item_key: 'document:1', remote_id: 'verified-file', status: 'verified')
    get retention_drive_path
    assert_response :success
    assert_select 'h1', 'Drive copies'
    assert_select 'h1', count: 1
    assert_includes response.body, 'owner@example.com'
    assert_select 'form[action=?] button', sync_retention_drive_path, text: 'Sync now'
    post disconnect_retention_drive_path
    assert_redirected_to retention_drive_path
    assert_nil connection.reload.refresh_token
    refute connection.enabled
    assert_equal 'verified', item.reload.status
  end
end
