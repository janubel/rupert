# frozen_string_literal: true

require 'digest'
require 'stringio'

module TeamChat
  # Keeps team chat files in the workspace's own Google Drive, through the same
  # Drive connection as Document retention (Uploads → Document retention), so
  # there is one Google consent per workspace and Rupert only ever sees files it
  # created (drive.file scope).
  #
  # Layout: "Rupert Team Chat — <workspace>/<room>/<file>". Every upload is
  # idempotent (the Drive id is reserved and saved first) and verified by size
  # and MD5 before the attachment counts as stored. Downloads are verified too.
  class DriveStore
    class Error < StandardError; end

    FOLDER_MIME = 'application/vnd.google-apps.folder'
    ROOT_KEY = 'team_chat.drive_root_folder'
    # Rupert keeps its own copy this long after Drive has a verified one.
    KEEP_LOCAL_FOR = 30.days
    FIELDS = 'id,name,mimeType,parents,trashed,size,md5Checksum,appProperties'

    def self.connection = RetentionDriveConnection.find_by(enabled: true)

    def self.available?
      RetentionDrive.configured? && connection&.connected?
    rescue StandardError
      false
    end

    def self.drive_url(id) = "https://drive.google.com/file/d/#{id}/view"

    def initialize(connection = self.class.connection)
      raise Error, 'Google Drive is not connected for this workspace.' unless connection&.connected? && connection.tenant_id == Current.tenant_id

      @connection = connection
      client = RetentionDrive.oauth_client
      client.refresh_token = connection.refresh_token
      client.fetch_access_token!
      @drive = RetentionDrive.service(client)
    end

    # Copies one attachment to Drive and records it. Safe to call again after any failure.
    def store!(attachment)
      return attachment if attachment.drive_status == 'stored'

      bytes = attachment.data
      raise Error, 'Rupert no longer has this file to copy.' if bytes.nil?

      folder = room_folder!(attachment.room)
      id = attachment.drive_file_id.presence || reserve_id
      attachment.update_columns(drive_file_id: id, updated_at: Time.current) if attachment.drive_file_id != id
      remote = remote(id)
      unless remote
        upload(attachment, id, folder, bytes)
        remote = remote(id)
      end
      md5 = Digest::MD5.hexdigest(bytes)
      unless remote && !remote.trashed && remote.md5_checksum == md5 && remote.size.to_i == bytes.bytesize
        raise Error, 'The Drive copy did not match the original; it will be tried again.'
      end

      attachment.update_columns(drive_status: 'stored', drive_md5: md5, drive_stored_at: Time.current, drive_error: nil, updated_at: Time.current)
      attachment
    end

    # The file's bytes from Drive, checked against the MD5 recorded when it was stored.
    def fetch(attachment)
      raise Error, 'This file is not in Google Drive.' if attachment.drive_file_id.blank?

      buffer = StringIO.new(+''.b)
      @drive.get_file(attachment.drive_file_id, download_dest: buffer)
      bytes = buffer.string
      raise Error, 'The Drive copy has changed since it was posted.' if attachment.drive_md5.present? && Digest::MD5.hexdigest(bytes) != attachment.drive_md5

      bytes
    end

    # Moves a deleted message's files to the Drive trash (best effort; Drive keeps them 30 days).
    def trash(ids)
      ids.compact_blank.each do |id|
        @drive.update_file(id, Google::Apis::DriveV3::File.new(trashed: true), fields: 'id')
      rescue Google::Apis::ClientError => e
        raise unless e.status_code == 404
      end
    end

    private

    def upload(attachment, id, folder, bytes)
      message = attachment.message
      metadata = Google::Apis::DriveV3::File.new(
        id: id, name: attachment.filename, parents: [folder], mime_type: attachment.content_type,
        description: "Posted in Rupert team chat (#{room_label(attachment.room)}) by #{message.author_name} on #{message.created_at.to_date.iso8601}.",
        app_properties: { 'rupert' => 'team_chat', 'attachment' => attachment.id.to_s, 'tenant' => @connection.tenant_id.to_s }
      )
      @drive.create_file(metadata, upload_source: StringIO.new(bytes), content_type: attachment.content_type, fields: 'id')
    rescue Google::Apis::ClientError => e
      raise unless e.status_code == 409 # already uploaded by an earlier attempt
    end

    def root_folder!
      setting = Setting.find_by(key: ROOT_KEY, tenant_id: Current.tenant_id)
      return setting.value if setting&.value.present? && folder?(setting.value)

      id = create_folder("Rupert Team Chat — #{@connection.tenant.name}", nil)
      Setting.find_or_create_for(ROOT_KEY, Current.tenant_id) { |row| row.value = id }
      id
    end

    def room_folder!(room)
      return room.drive_folder_id if room.drive_folder_id.present? && folder?(room.drive_folder_id)

      id = create_folder(room_label(room), root_folder!)
      room.update_columns(drive_folder_id: id)
      id
    end

    def room_label(room)
      return "##{room.name}" if room.channel?

      room.direct? ? "#{room.display_name} — #{room.created_by&.display_name}" : "Direct — #{room.members.map(&:display_name).sort.join(' & ')}"
    end

    def create_folder(name, parent)
      metadata = Google::Apis::DriveV3::File.new(name: name, mime_type: FOLDER_MIME, parents: parent ? [parent] : nil,
        app_properties: { 'rupert' => 'team_chat' })
      @drive.create_file(metadata, fields: 'id').id
    end

    def folder?(id)
      found = remote(id)
      found && !found.trashed && found.mime_type == FOLDER_MIME
    end

    def reserve_id = @drive.generate_file_ids(count: 1, space: 'drive', type: 'files').ids.fetch(0)

    def remote(id)
      @drive.get_file(id, fields: FIELDS)
    rescue Google::Apis::ClientError => e
      raise unless e.status_code == 404

      nil
    end
  end
end
