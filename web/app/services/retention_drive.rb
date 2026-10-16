# frozen_string_literal: true

require 'google/apis/drive_v3'
require 'signet/oauth_2/client'
require 'digest'
require 'stringio'
require 'tempfile'

# Tenant-owned evidence copies. No sharing, deletion, conversion or backup pruning.
class RetentionDrive
  class Error < StandardError; end
  FOLDER_MIME = 'application/vnd.google-apps.folder'
  SOURCES = { 'document' => ReconciliationDocument, 'swipesimple' => SwipesimpleExport, 'authorize_net' => AuthorizeNetPortalExport }.freeze
  BATCH_SIZE = 25

  class << self
    def configured?
      GoogleDriveBackupService.configured?
    end

    def auth_url(redirect_uri:, state:)
      GoogleDriveBackupService.auth_url(redirect_uri: redirect_uri, state: state)
    end

    def exchange_code!(code, redirect_uri:)
      client = oauth_client
      client.redirect_uri = redirect_uri
      client.code = code
      client.fetch_access_token!
      raise Error, 'Google did not return unattended access. Reconnect and approve consent.' if client.refresh_token.blank?

      drive = service(client)
      user = drive.get_about(fields: 'user(emailAddress,permissionId)').user
      raise Error, 'Google did not identify the destination account.' if user.permission_id.blank? || user.email_address.blank?

      row = RetentionDriveConnection.find_or_initialize_by(tenant_id: Current.tenant_id)
      row.update!(refresh_token: client.refresh_token, account_email: user.email_address,
        generation: Digest::SHA256.hexdigest(user.permission_id), enabled: true, sync_lease_token: nil, sync_lease_at: nil, last_error: nil)
      row
    end

    def oauth_client
      raise Error, 'Google Drive app credentials need platform setup.' unless configured?

      Signet::OAuth2::Client.new(client_id: EnvStore.platform_fetch('GOOGLE_DRIVE_CLIENT_ID', ''),
        client_secret: EnvStore.platform_fetch('GOOGLE_DRIVE_CLIENT_SECRET', ''), scope: GoogleDriveBackupService::SCOPE,
        authorization_uri: 'https://accounts.google.com/o/oauth2/auth', token_credential_uri: 'https://oauth2.googleapis.com/token')
    end

    def service(client)
      Google::Apis::DriveV3::DriveService.new.tap do |drive|
        drive.authorization = client
        drive.client_options.open_timeout_sec = 10
        drive.client_options.read_timeout_sec = 60
        drive.client_options.send_timeout_sec = 60
        drive.request_options.retries = 1
      end
    end
  end

  def initialize(connection)
    raise Error, 'Workspace does not match the Drive connection.' unless Current.tenant_id.present? && connection.tenant_id == Current.tenant_id

    @connection = connection
    @generation = connection.generation
  end

  def sync!
    return unless @connection.connected? && @connection.enabled

    @lease = SecureRandom.hex(24)
    claimed = RetentionDriveConnection.where(id: @connection.id, enabled: true, generation: @generation)
      .where('sync_lease_at IS NULL OR sync_lease_at < ?', 20.minutes.ago)
      .update_all(sync_lease_token: @lease, sync_lease_at: Time.current)
    return if claimed.zero?

    begin
      client = self.class.oauth_client
      client.refresh_token = @connection.refresh_token
      client.fetch_access_token!
      @drive = self.class.service(client)
      enqueue_manifest!
      items = scope.where.not("item_key LIKE ?", 'folder:%').where.not(status: 'verified')
        .order(Arel.sql('COALESCE(last_attempt_at, created_at) ASC'), :id).limit(BATCH_SIZE)
      deadline = 5.minutes.from_now
      items.each do |item|
        break if Time.current >= deadline || !lease_current?

        sync_item!(item)
      end
      @connection.update!(last_synced_at: Time.current, last_error: scope.where(status: 'failed').exists? ? 'Some files need retry. Originals remain safe in Rupert.' : nil) if lease_current?
    rescue StandardError => e
      @connection.update!(last_error: error_message(e)) if lease_current?
      raise
    ensure
      RetentionDriveConnection.where(id: @connection.id, sync_lease_token: @lease).update_all(sync_lease_token: nil, sync_lease_at: nil)
    end
  end

  private

  def scope
    RetentionDriveItem.where(generation: @generation)
  end

  def lease_current?
    RetentionDriveConnection.where(id: @connection.id, enabled: true, generation: @generation, sync_lease_token: @lease).exists?
  end

  def enqueue_manifest!
    SOURCES.each do |prefix, model|
      model.select(:id).find_each do |record|
        scope.find_or_create_by!(item_key: "#{prefix}:#{record.id}")
      end
    end
  end

  def source_for(item)
    prefix, id = item.item_key.split(':', 2)
    record = SOURCES.fetch(prefix).find(id)
    if prefix == 'document'
      bytes = record.original_bytes
      category = if %w[daily_archive period_archive].include?(record.kind)
        'Report Archives'
      elsif record.kind == 'source_export' && record.metadata['coverage'] == 'normalized_source_snapshot'
        'Source Snapshots'
      else
        'Originals'
      end
      { bytes: bytes, name: record.filename, date: record.period_from, source: record.source.humanize,
        category: category, content_type: record.content_type, context: "Covered dates: #{record.period_from} to #{record.period_to}. #{record.kind.humanize}." }
    else
      bytes = record.original_csv.b
      raise Error, 'Original source checksum mismatch.' if record.sha256.present? && Digest::SHA256.hexdigest(bytes) != record.sha256

      { bytes: bytes, name: "#{prefix}-#{record.kind}.csv", date: record.exported_at.in_time_zone.to_date,
        source: prefix == 'swipesimple' ? 'SwipeSimple' : 'Authorize.net', category: 'Native Exports', content_type: 'text/csv',
        context: "Export received: #{record.exported_at.iso8601}. Folder date is the export date, not transaction coverage. #{record.kind.humanize}." }
    end
  end

  def sync_item!(item)
    item.update!(last_attempt_at: Time.current)
    source = source_for(item)
    bytes = source.fetch(:bytes)
    sha = Digest::SHA256.hexdigest(bytes)
    root = ensure_folder!('root', "Rupert Document Retention — #{@connection.tenant.name}")
    parts = [source[:date].strftime('%Y'), source[:date].strftime('%m'), source[:source], source[:category]]
    parent = root
    parts.each_with_index { |name, i| parent = ensure_folder!(parts.first(i + 1).join('/'), name, parent) }
    name = "#{source[:date]}_#{item.item_key.tr(':', '-')}_#{sha.first(8)}_#{source[:name]}".gsub(/[\x00-\x1f\/\\]/, '_').first(220)
    item.update!(remote_id: item.remote_id.presence || generate_id, sha256: sha, byte_size: bytes.bytesize,
      display_name: name, folder_path: parts.join('/'))
    remote = remote_file(item.remote_id)
    unless remote
      raise Error, 'Connection was paused during sync.' unless lease_current?

      metadata = Google::Apis::DriveV3::File.new(id: item.remote_id, name: name, parents: [parent],
        mime_type: source[:content_type], description: "Rupert retained evidence. #{source[:context]} SHA-256: #{sha}", app_properties: properties(item))
      begin
        @drive.create_file(metadata, upload_source: StringIO.new(bytes), content_type: source[:content_type], fields: 'id')
      rescue Google::Apis::ClientError => e
        raise unless e.status_code == 409 # Lost upload response: verify the previously reserved ID.
      end
      remote = @drive.get_file(item.remote_id, fields: remote_fields)
    end
    verify!(item, remote, bytes, parent)
    item.update!(status: 'verified', verified_at: Time.current, last_error: nil)
  rescue StandardError => e
    item.update!(status: 'failed', last_error: error_message(e))
  end

  def ensure_folder!(key, name, parent = nil)
    @folders ||= {}
    return @folders[key] if @folders.key?(key)

    item = scope.find_or_create_by!(item_key: "folder:#{key}")
    # Verified folders are checked again each batch; moved/trashed folders stop the upload.
    item.update!(remote_id: item.remote_id.presence || generate_id)
    remote = remote_file(item.remote_id)
    unless remote
      raise Error, 'Connection was paused during sync.' unless lease_current?

      metadata = Google::Apis::DriveV3::File.new(id: item.remote_id, name: name, mime_type: FOLDER_MIME,
        parents: parent ? [parent] : nil, app_properties: properties(item))
      begin
        @drive.create_file(metadata, fields: 'id')
      rescue Google::Apis::ClientError => e
        raise unless e.status_code == 409
      end
      remote = @drive.get_file(item.remote_id, fields: remote_fields)
    end
    unless !remote.trashed && !remote.shared && remote.mime_type == FOLDER_MIME && remote.app_properties == properties(item) && (!parent || remote.parents&.include?(parent))
      raise Error, 'Retention folder changed or is unavailable. Restore its original location before retrying.'
    end
    item.update!(status: 'verified', display_name: name, verified_at: Time.current)
    @folders[key] = item.remote_id
  end

  def verify!(item, remote, bytes, parent)
    unless !remote.trashed && !remote.shared && remote.parents&.include?(parent) && remote.app_properties == properties(item) &&
        remote.size.to_i == bytes.bytesize && remote.md5_checksum == Digest::MD5.hexdigest(bytes)
      raise Error, 'Drive copy did not pass identity, location, size or checksum verification.'
    end
    Tempfile.create(['rupert-evidence-verify-', '.bin']) do |copy|
      copy.chmod(0o600)
      @drive.get_file(item.remote_id, download_dest: copy.path)
      raise Error, 'Downloaded Drive copy differs from the retained original.' unless File.size(copy.path) == bytes.bytesize && Digest::SHA256.file(copy.path).hexdigest == item.sha256
    end
  end

  def generate_id
    @drive.generate_file_ids(count: 1, space: 'drive', type: 'files').ids.fetch(0)
  end

  def remote_file(id)
    @drive.get_file(id, fields: remote_fields)
  rescue Google::Apis::ClientError => e
    raise unless e.status_code == 404

    nil
  end

  def remote_fields
    'id,size,md5Checksum,mimeType,parents,trashed,shared,appProperties'
  end

  def properties(item)
    { 'rupert_retention' => Digest::SHA256.hexdigest("#{Current.tenant_id}:#{@generation}:#{item.item_key}") }
  end

  def error_message(error)
    return error.message if error.is_a?(Error)
    return 'Google authorization expired or was declined. Reconnect Google Drive.' if error.is_a?(Signet::AuthorizationError) || (error.respond_to?(:status_code) && error.status_code == 401)
    return 'Google Drive denied access. Check account consent, folder access and available storage, then retry.' if error.respond_to?(:status_code) && error.status_code == 403

    'Upload could not be verified. Originals remain in Rupert; automatic sync will retry.'
  end
end
