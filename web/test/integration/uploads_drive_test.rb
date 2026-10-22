# frozen_string_literal: true

require 'test_helper'
require_relative '../support/fake_drive'

class UploadsDriveIntegrationTest < ActionDispatch::IntegrationTest
  CSV_BYTES = "Account,Type,Detail Type,Description,Balance\nChecking,Bank,Checking,Main,1000.00\n"

  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    post login_path, params: { email: 'admin@example.com', password: 'password' }
    @fake = FakeDrive.new(files: { 'a' => FakeDrive.file('a', 'coa.csv', CSV_BYTES), 'doc' => FakeDrive.file('doc', 'Sheet', 'x', mime: 'application/vnd.google-apps.spreadsheet') },
      folders: { 'folder-1' => 'QB exports', 'f2' => 'Other' })
    DriveSource.any_instance.stubs(:build_drive).returns(@fake)
  end

  teardown { Current.reset }

  def connect!(folder: 'folder-1')
    ImportDriveConnection.create!(refresh_token: 'r', account_email: 'owner@example.test', folder_id: folder, folder_name: ('QB exports' if folder))
  end

  test 'the uploads page offers Google Drive next to the device upload' do
    get uploads_path
    assert_includes response.body, 'choose files'
    assert_includes response.body, uploads_drive_path
  end

  test 'not connected: explains setup or offers the connect button' do
    DriveSource.stubs(:configured?).returns(false)
    get uploads_drive_path
    assert_response :success
    assert_includes response.body, 'not set up'
    DriveSource.stubs(:configured?).returns(true)
    get uploads_drive_path
    assert_includes response.body, 'read-only'
    assert_includes response.body, 'Connect Google Drive'
  end

  test 'connect starts consent with the read-only scope and a bound state' do
    DriveSource.stubs(:configured?).returns(true)
    EnvStore.stubs(:platform_fetch).with('GOOGLE_DRIVE_CLIENT_ID', '').returns('cid')
    EnvStore.stubs(:platform_fetch).with('GOOGLE_DRIVE_CLIENT_SECRET', '').returns('secret')
    post connect_uploads_drive_path
    assert_response :redirect
    assert_match(%r{\Ahttps://accounts\.google\.com/}, response.location)
    assert_includes response.location, 'scope=https://www.googleapis.com/auth/drive.readonly'
    assert_match(/state=uploads_drive:/, response.location)
    assert_not_includes response.location, 'auth/drive.file'
  end

  test 'the callback needs the matching state and then stores an encrypted read-only connection' do
    DriveSource.stubs(:configured?).returns(true)
    EnvStore.stubs(:platform_fetch).with('GOOGLE_DRIVE_CLIENT_ID', '').returns('cid')
    EnvStore.stubs(:platform_fetch).with('GOOGLE_DRIVE_CLIENT_SECRET', '').returns('secret')
    post connect_uploads_drive_path
    state = Rack::Utils.parse_query(URI(response.location).query)['state']
    get '/auth/google/callback', params: { state: 'uploads_drive:forged', code: 'c' }
    assert_redirected_to login_path
    assert_equal 0, ImportDriveConnection.count

    post connect_uploads_drive_path
    state = Rack::Utils.parse_query(URI(response.location).query)['state']
    DriveSource.expects(:exchange_code!).with('c', has_entries(redirect_uri: anything)).once.returns(connect!)
    get '/auth/google/callback', params: { state: state, code: 'c' }
    assert_redirected_to uploads_drive_path
    assert_equal 1, ImportDriveConnection.count
    assert ActivityLog.where(action: 'uploads_drive_connected').exists?
  end

  test 'choose a folder, list its files and copy one into the inbox' do
    connect!(folder: nil)
    get uploads_drive_path
    assert_includes response.body, 'Choose the folder Rupert may read'
    post folder_uploads_drive_path, params: { folder_id: 'folder-1' }
    assert_equal 'folder-1', ImportDriveConnection.first.folder_id
    get uploads_drive_path
    assert_includes response.body, 'coa.csv'
    assert_includes response.body, 'Google document'
    post import_uploads_drive_path, params: { file_ids: ['a'] }
    upload = Upload.last
    assert_redirected_to upload_path(upload)
    assert_equal ['drive', 'quickbooks'], [upload.origin, upload.importer_key]
    assert_equal 0, ImportBatch.count
    follow_redirect!
    assert_includes response.body, 'Google Drive'
  end

  test 'selecting nothing or a refused file shows the reason' do
    connect!
    post import_uploads_drive_path, params: { file_ids: [] }
    assert_redirected_to uploads_drive_path
    assert_match(/Select at least one/, flash[:alert])
    post import_uploads_drive_path, params: { file_ids: ['doc'] }
    assert_match(/not converted/, flash[:alert])
    assert_equal 0, Upload.where(retained: true).count
  end

  test 'disconnect removes the token and the folder but keeps copied files' do
    connect!
    post import_uploads_drive_path, params: { file_ids: ['a'] }
    post disconnect_uploads_drive_path
    connection = ImportDriveConnection.first
    assert_nil connection.refresh_token
    assert_nil connection.folder_id
    assert_equal 1, Upload.where(retained: true).count
  end

  test 'someone without uploads or settings access is refused' do
    reader = User.create!(tenant: @tenant, role: 'reader', email: 'reader@example.com', password: 'password123')
    delete logout_path
    post login_path, params: { email: 'reader@example.com', password: 'password123' }
    get uploads_drive_path
    assert_match(/permission/, flash[:alert])
    post connect_uploads_drive_path
    assert_match(/permission/, flash[:alert])
    assert reader
  end
end
