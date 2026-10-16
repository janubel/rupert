# frozen_string_literal: true

require 'test_helper'

class RetentionDriveTest < ActiveSupport::TestCase
  class FakeDrive
    attr_reader :files, :creates
    attr_accessor :lose_next_upload, :corrupt_download

    def initialize
      @files = {}
      @creates = 0
      @next_id = 0
    end

    def generate_file_ids(**)
      @next_id += 1
      Struct.new(:ids).new(["drive-#{@next_id}"])
    end

    def create_file(metadata, upload_source: nil, **)
      @creates += 1
      bytes = upload_source&.read
      @files[metadata.id] = { metadata: metadata, bytes: bytes }
      if bytes && lose_next_upload
        self.lose_next_upload = false
        raise IOError, 'Lost response after remote commit'
      end
      metadata
    end

    def get_file(id, download_dest: nil, **)
      file = @files[id]
      raise Google::Apis::ClientError.new('Missing', status_code: 404) unless file
      if download_dest
        File.binwrite(download_dest, corrupt_download ? 'corrupted' : file[:bytes])
        return
      end
      metadata = file[:metadata]
      Google::Apis::DriveV3::File.new(id: id, mime_type: metadata.mime_type, parents: metadata.parents,
        app_properties: metadata.app_properties, size: file[:bytes]&.bytesize, md5_checksum: file[:bytes] && Digest::MD5.hexdigest(file[:bytes]), trashed: false, shared: metadata.shared || false)
    end
  end

  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    @connection = RetentionDriveConnection.create!(refresh_token: 'private-refresh', account_email: 'owner@example.com', generation: 'account-one', enabled: true)
    @drive = FakeDrive.new
    client = mock('oauth')
    client.stubs(:refresh_token=)
    client.stubs(:fetch_access_token!)
    RetentionDrive.stubs(:oauth_client).returns(client)
    RetentionDrive.stubs(:service).returns(@drive)
  end
  teardown { Current.reset }

  def original(name = 'invoice.pdf')
    ReconciliationEvidence.retain!(bytes: "%PDF-1.4\nInvoice original #{name}\n", filename: name, source: 'bank', kind: 'invoice', from: '2026-10-14', to: '2026-10-14')
  end

  test 'original bytes are organized verified and replayed without duplicates or local mutations' do
    doc = original
    RetentionDrive.new(@connection).sync!
    item = RetentionDriveItem.find_by!(item_key: "document:#{doc.id}")
    assert_equal 'verified', item.status
    assert_equal '2026/10/Bank/Originals', item.folder_path
    assert_equal doc.original_bytes, @drive.files.fetch(item.remote_id).fetch(:bytes)
    assert_equal doc.sha256, item.sha256
    assert_match(%r{drive.google.com/file/d/}, item.drive_url)
    created = @drive.creates
    RetentionDrive.new(@connection.reload).sync!
    assert_equal created, @drive.creates
    assert_equal 1, ReconciliationDocument.count
    refute_includes RetentionDriveConnection.connection.select_value("SELECT refresh_token FROM retention_drive_connections WHERE id=#{@connection.id}"), 'private-refresh'
  end

  test 'a lost upload response retries the reserved ID instead of duplicating its file' do
    doc = original
    @drive.lose_next_upload = true
    RetentionDrive.new(@connection).sync!
    item = RetentionDriveItem.find_by!(item_key: "document:#{doc.id}")
    assert_equal 'failed', item.status
    reserved_id = item.remote_id
    created = @drive.creates
    RetentionDrive.new(@connection.reload).sync!
    assert_equal 'verified', item.reload.status
    assert_equal reserved_id, item.remote_id
    assert_equal created, @drive.creates
  end

  test 'corrupt download is never marked copied and keeps original intact' do
    doc = original
    @drive.corrupt_download = true
    RetentionDrive.new(@connection).sync!
    item = RetentionDriveItem.find_by!(item_key: "document:#{doc.id}")
    assert_equal 'failed', item.status
    assert_nil item.drive_url
    assert_nil item.verified_at
    assert_equal "%PDF-1.4\nInvoice original invoice.pdf\n", doc.original_bytes
    @drive.corrupt_download = false
    RetentionDrive.new(@connection.reload).sync!
    assert_equal 'verified', item.reload.status
  end

  test 'only the current tenant is exported and connection mismatch is refused' do
    doc = original
    other = Tenant.create!(name: 'Other evidence', subdomain: 'other-evidence')
    Current.set(tenant: other) { original('foreign.pdf') }
    RetentionDrive.new(@connection).sync!
    assert_equal ["document:#{doc.id}"], RetentionDriveItem.where.not('item_key LIKE ?', 'folder:%').pluck(:item_key)
    Current.set(tenant: other) { assert_raises(RetentionDrive::Error) { RetentionDrive.new(@connection) } }
  end

  test 'native invoice and gateway originals keep bytes and export dates without conversion' do
    bytes = "invoice,total\nA,12.00\n"
    invoice = SwipesimpleExport.create!(merchant_account: 'test', fingerprint: 'original-invoice', sha256: Digest::SHA256.hexdigest(bytes),
      exported_at: Time.zone.parse('2026-10-15 12:00'), original_csv: bytes, currency: 'USD', source_timezone: 'America/New_York', kind: 'invoices')
    portal = AuthorizeNetPortalExport.create!(gateway_id: 'test-gateway', fingerprint: 'original-portal', sha256: Digest::SHA256.hexdigest(bytes),
      exported_at: Time.zone.parse('2026-10-15 12:00'), original_csv: bytes, records_json: '[]', kind: 'settled')
    RetentionDrive.new(@connection).sync!
    ["swipesimple:#{invoice.id}", "authorize_net:#{portal.id}"].each do |key|
      item = RetentionDriveItem.find_by!(item_key: key)
      assert_equal 'verified', item.status
      assert_match(%r{2026/10/.*/Native Exports}, item.folder_path)
      assert_equal bytes, @drive.files.fetch(item.remote_id).fetch(:bytes)
    end
  end

  test 'paused connections and overlapping sync leases never upload' do
    original
    @connection.update!(enabled: false)
    RetentionDrive.new(@connection).sync!
    assert_empty @drive.files
    @connection.update!(enabled: true, sync_lease_token: 'other-worker', sync_lease_at: Time.current)
    RetentionDrive.new(@connection).sync!
    assert_empty @drive.files
  end

  test 'a shared retention folder stops new uploads without changing its permissions' do
    original
    RetentionDrive.new(@connection).sync!
    folder = RetentionDriveItem.find_by!(item_key: 'folder:root')
    @drive.files.fetch(folder.remote_id).fetch(:metadata).shared = true
    doc = original('another-invoice.pdf')
    RetentionDrive.new(@connection.reload).sync!
    item = RetentionDriveItem.find_by!(item_key: "document:#{doc.id}")
    assert_equal 'failed', item.status
    assert_nil item.drive_url
    assert_nil item.remote_id
  end

  test 'all pending originals enter the manifest while a pass respects its batch bound' do
    26.times { |n| original("invoice-#{n}.pdf") }
    RetentionDrive.new(@connection).sync!
    files = RetentionDriveItem.where.not('item_key LIKE ?', 'folder:%')
    assert_equal 26, files.count
    assert_equal 25, files.where(status: 'verified').count
    RetentionDrive.new(@connection.reload).sync!
    assert_equal 26, files.where(status: 'verified').count
  end
end
