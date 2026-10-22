# frozen_string_literal: true

require 'test_helper'

class TeamChatDriveStoreTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  # In-memory Drive: files by id, with the calls DriveStore makes.
  class FakeDrive
    attr_reader :files, :uploads
    attr_accessor :fail_upload, :corrupt_download

    def initialize
      @files = {}
      @uploads = 0
      @next = 0
    end

    def generate_file_ids(**)
      @next += 1
      Struct.new(:ids).new(["file-#{@next}"])
    end

    def create_file(metadata, upload_source: nil, **)
      raise Google::Apis::ServerError, 'backend error' if upload_source && fail_upload

      @uploads += 1 if upload_source
      id = metadata.id || generate_file_ids.ids.first
      bytes = upload_source&.read
      @files[id] = { metadata: metadata, bytes: bytes, trashed: false }
      Google::Apis::DriveV3::File.new(id: id)
    end

    def get_file(id, download_dest: nil, **)
      file = @files[id]
      raise Google::Apis::ClientError.new('Missing', status_code: 404) unless file

      if download_dest
        download_dest.write(corrupt_download ? 'corrupted' : file[:bytes])
        return
      end
      bytes = file[:bytes]
      Google::Apis::DriveV3::File.new(id: id, name: file[:metadata].name, mime_type: file[:metadata].mime_type, parents: file[:metadata].parents,
        trashed: file[:trashed], size: bytes&.bytesize, md5_checksum: bytes && Digest::MD5.hexdigest(bytes))
    end

    def update_file(id, metadata, **)
      @files.fetch(id)[:trashed] = metadata.trashed
    end
  end

  PNG = "\x89PNG\r\n\x1A\n".b + ('pixels' * 40)

  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    @user = users(:regular_user)
    Current.user = @user
    RetentionDriveConnection.create!(refresh_token: 'private-refresh', account_email: 'owner@example.com', generation: 'account-one', enabled: true)
    @drive = FakeDrive.new
    client = mock('oauth')
    client.stubs(:refresh_token=)
    client.stubs(:fetch_access_token!)
    RetentionDrive.stubs(:configured?).returns(true)
    RetentionDrive.stubs(:oauth_client).returns(client)
    RetentionDrive.stubs(:service).returns(@drive)
    @room = TeamChat::Room.ensure_defaults!(@user)
  end

  teardown { Current.reset }

  def upload
    file = Tempfile.new(['shelf', '.png'])
    file.binmode
    file.write(PNG)
    file.rewind
    Rack::Test::UploadedFile.new(file.path, 'image/png', true, original_filename: 'shelf-3.png')
  end

  # Jobs reset Current when they finish; the test carries on as the same person.
  def run_jobs(only, &block)
    block ? perform_enqueued_jobs(only: only, &block) : perform_enqueued_jobs(only: only)
  ensure
    Current.tenant = @tenant
    Current.user = @user
  end

  def post_file
    TeamChat::Post.call(room: @room, user: @user, body: 'shelf', files: [upload]).message.attachments.first
  end

  test 'posting a file queues a copy to Drive; the copy lands in the room folder and is verified' do
    attachment = nil
    assert_enqueued_with(job: TeamChat::AttachmentDriveJob) { attachment = post_file }
    run_jobs(TeamChat::AttachmentDriveJob)
    attachment.reload
    assert_equal 'stored', attachment.drive_status
    assert_equal Digest::MD5.hexdigest(PNG), attachment.drive_md5
    stored = @drive.files.fetch(attachment.drive_file_id)
    assert_equal 'shelf-3.png', stored[:metadata].name
    room_folder = @drive.files.fetch(stored[:metadata].parents.first)
    assert_equal '#general', room_folder[:metadata].name
    root = @drive.files.fetch(room_folder[:metadata].parents.first)
    assert_equal "Rupert Team Chat — #{@tenant.name}", root[:metadata].name
    assert_equal TeamChat::DriveStore.drive_url(attachment.drive_file_id), attachment.as_payload(@room)[:drive_url]

    second = post_file
    run_jobs(TeamChat::AttachmentDriveJob)
    assert_equal stored[:metadata].parents.first, @drive.files.fetch(second.reload.drive_file_id)[:metadata].parents.first, 'folders are reused'
  end

  test 'a failed copy is recorded and the daily sweep retries it, then drops the local copy after the keep period' do
    @drive.fail_upload = true
    attachment = post_file
    run_jobs(TeamChat::AttachmentDriveJob)
    assert_equal 'failed', attachment.reload.drive_status
    assert attachment.drive_error.present?
    assert attachment.data.present?, 'Rupert keeps the file until Drive has it'

    @drive.fail_upload = false
    run_jobs(TeamChat::AttachmentDriveJob) { TeamChat::AttachmentDriveSweepJob.perform_now }
    Current.tenant = @tenant
    assert_equal 'stored', attachment.reload.drive_status
    assert attachment.data.present?

    travel TeamChat::DriveStore::KEEP_LOCAL_FOR + 1.day
    TeamChat::AttachmentDriveSweepJob.perform_now
    Current.tenant = @tenant
    assert_nil attachment.reload.data
    assert_equal PNG, TeamChat::DriveStore.new.fetch(attachment)
  end

  test 'a Drive copy that changed is refused when fetched' do
    attachment = post_file
    run_jobs(TeamChat::AttachmentDriveJob)
    @drive.corrupt_download = true
    assert_raises(TeamChat::DriveStore::Error) { TeamChat::DriveStore.new.fetch(attachment.reload) }
  end

  test 'without a Drive connection files stay in Rupert and nothing is queued' do
    RetentionDriveConnection.delete_all
    assert_no_enqueued_jobs(only: TeamChat::AttachmentDriveJob) { post_file }
  end

  test 'deleting a message moves its Drive copies to the trash' do
    attachment = post_file
    run_jobs(TeamChat::AttachmentDriveJob)
    id = attachment.reload.drive_file_id
    message = attachment.message
    run_jobs(TeamChat::DriveTrashJob) { message.soft_delete! }
    assert @drive.files.fetch(id)[:trashed]
  end
end
