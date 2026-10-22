# frozen_string_literal: true

require 'test_helper'
require_relative '../support/fake_drive'

class DriveSourceTest < ActiveSupport::TestCase
  CSV_BYTES = "Account,Type,Detail Type,Description,Balance\nChecking,Bank,Checking,Main,1000.00\n"

  setup do
    Current.tenant = tenants(:default_tenant)
    @admin = users(:regular_user)
    @connection = ImportDriveConnection.create!(refresh_token: 'refresh-secret', account_email: 'owner@example.test', folder_id: 'folder-1', folder_name: 'QB exports')
  end

  teardown { Current.reset }

  def source(files = {}, folders: { 'f9' => 'Other' }) = DriveSource.new(@connection, drive: FakeDrive.new(files: files, folders: folders))

  test 'lists only the chosen folder and says why a file cannot be copied' do
    drive = FakeDrive.new(files: {
      'a' => FakeDrive.file('a', 'coa.csv', CSV_BYTES),
      'b' => FakeDrive.file('b', 'sheet', 'x', mime: 'application/vnd.google-apps.spreadsheet'),
      'c' => FakeDrive.file('c', 'notes.docx', 'x', mime: 'application/msword'),
      'd' => FakeDrive.file('d', 'elsewhere.csv', CSV_BYTES, parents: ['other-folder']),
      'e' => FakeDrive.file('e', 'old.csv', CSV_BYTES, trashed: true)
    })
    rows = DriveSource.new(@connection, drive: drive).files
    assert_equal %w[coa.csv sheet notes.docx], rows.map(&:name)
    assert_equal [true, false, false], rows.map(&:importable)
    assert_match(/Google document/, rows[1].note)
    assert_match(/Unsupported/, rows[2].note)
    assert_includes drive.queries.last, "'folder-1' in parents"
    assert_includes drive.queries.last, 'trashed = false'
  end

  test 'copying a file keeps it unchanged in the inbox with origin Google Drive and recognizes it' do
    result = source({ 'a' => FakeDrive.file('a', 'coa.csv', CSV_BYTES) }).import!(['a'], actor: @admin)
    upload = result.first.upload
    assert result.first.created
    assert_equal ['drive', 'coa.csv', CSV_BYTES], [upload.origin, upload.filename, upload.original_bytes]
    assert_equal 'quickbooks', upload.importer_key
    assert_equal 0, ImportBatch.count, 'copying stages nothing; the normal dry run and approval come next'
  end

  test 'the same file copied twice is a duplicate, not a second copy' do
    drive = source({ 'a' => FakeDrive.file('a', 'coa.csv', CSV_BYTES) })
    drive.import!(['a'], actor: @admin)
    again = drive.import!(['a'], actor: @admin).first
    assert_equal 'duplicate', again.upload.status
    assert_equal 1, Upload.where(retained: true).count
  end

  test 'a file moved out of the folder, trashed, converted, oversize or corrupt is refused with a reason and the others still copy' do
    files = {
      'ok' => FakeDrive.file('ok', 'ok.csv', CSV_BYTES),
      'moved' => FakeDrive.file('moved', 'moved.csv', CSV_BYTES, parents: ['somewhere']),
      'trash' => FakeDrive.file('trash', 'trash.csv', CSV_BYTES, trashed: true),
      'doc' => FakeDrive.file('doc', 'doc', 'x', mime: 'application/vnd.google-apps.document'),
      'big' => FakeDrive.file('big', 'big.csv', CSV_BYTES, size: Uploads::Limits::MAX_FILE_BYTES + 1),
      'bad' => FakeDrive.file('bad', 'bad.csv', CSV_BYTES, md5: 'deadbeef')
    }
    results = source(files).import!(files.keys, actor: @admin)
    by_name = results.to_h { |r| [r.name, r] }
    assert by_name['ok.csv'].upload
    assert_match(/not in the chosen folder/, by_name['moved.csv'].error)
    assert_match(/not in the chosen folder/, by_name['trash.csv'].error)
    assert_match(/not converted/, by_name['doc'].error)
    assert_match(/larger than/, by_name['big.csv'].error)
    assert_match(/checksum/, by_name['bad.csv'].error)
    assert_equal 1, Upload.where(retained: true).count
  end

  test 'limits and preconditions' do
    drive = source({ 'a' => FakeDrive.file('a', 'coa.csv', CSV_BYTES) })
    assert_raises(DriveSource::Error) { drive.import!([], actor: @admin) }
    assert_raises(DriveSource::Error) { drive.import!(Array.new(11) { |i| "id#{i}" }, actor: @admin) }
    @connection.update!(folder_id: nil)
    assert_raises(DriveSource::Error) { DriveSource.new(@connection, drive: FakeDrive.new).files }
  end

  test 'choosing a folder verifies it is a folder; a file id is refused' do
    drive = FakeDrive.new(files: { 'a' => FakeDrive.file('a', 'coa.csv', CSV_BYTES) }, folders: { 'f9' => 'Exports 2025' })
    DriveSource.new(@connection, drive: drive).choose_folder!('f9')
    assert_equal ['f9', 'Exports 2025'], [@connection.reload.folder_id, @connection.folder_name]
    assert_raises(DriveSource::Error) { DriveSource.new(@connection, drive: drive).choose_folder!('a') }
  end

  test 'a workspace cannot use another workspace’s connection' do
    other = Tenant.create!(id: 'other-tenant', name: 'Other', subdomain: 'other', shopify_shop_domain: 'other.myshopify.com', status: 'active')
    Current.tenant = other
    assert_raises(DriveSource::Error) { DriveSource.new(@connection, drive: FakeDrive.new) }
    assert_equal 0, ImportDriveConnection.count
  end

  test 'the refresh token is encrypted at rest' do
    assert_not_includes ActiveRecord::Base.connection.select_value('SELECT refresh_token FROM import_drive_connections').to_s, 'refresh-secret'
  end

  test 'folder names with quotes cannot break out of the Drive query' do
    drive = FakeDrive.new(files: {})
    @connection.update!(folder_id: "x' or '1'='1")
    DriveSource.new(@connection, drive: drive).files
    assert_includes drive.queries.last, "'x\\' or \\'1\\'=\\'1' in parents"
  end
end
