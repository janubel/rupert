# frozen_string_literal: true

require 'google/apis/drive_v3'
require 'signet/oauth_2/client'
require 'digest'
require 'stringio'

# Fetches files from a Google Drive folder the person authorized into the
# Uploads inbox, as an alternative to uploading them from a device. Everything it
# fetches goes through Uploads::Intake exactly like a browser upload, so it is
# kept byte for byte, recognized and previewed, and changes no business record
# until the usual dry run and approval.
#
# Access is read-only (`drive.readonly`). Google offers no narrower scope for
# reading files a person made elsewhere, so the app limits itself: it lists and
# reads only inside the one folder chosen here, never writes, shares, moves or
# deletes, and refuses anything outside that folder, in the trash, over the size
# cap, of an unsupported type or whose checksum does not match. Google-native
# documents (Docs, Sheets) are not converted; download them as CSV or Excel into
# the folder first.
class DriveSource
  class Error < StandardError; end

  SCOPE = 'https://www.googleapis.com/auth/drive.readonly'
  FOLDER_MIME = 'application/vnd.google-apps.folder'
  NATIVE_PREFIX = 'application/vnd.google-apps.'
  MAX_LISTED = 200
  MAX_PER_IMPORT = 10

  FileRow = Struct.new(:id, :name, :size, :modified_at, :importable, :note, keyword_init: true)
  Fetched = Struct.new(:name, :upload, :created, :error, keyword_init: true)

  class << self
    def configured?
      EnvStore.platform_fetch('GOOGLE_DRIVE_CLIENT_ID', '').present? && EnvStore.platform_fetch('GOOGLE_DRIVE_CLIENT_SECRET', '').present?
    end

    def auth_url(redirect_uri:, state:)
      raise Error, 'Google Drive app credentials need platform setup.' unless configured?

      client = oauth_client
      client.redirect_uri = redirect_uri
      client.authorization_uri(access_type: 'offline', prompt: 'consent', state: state).to_s
    end

    def exchange_code!(code, redirect_uri:, actor: nil)
      client = oauth_client
      client.redirect_uri = redirect_uri
      client.code = code
      client.fetch_access_token!
      raise Error, 'Google did not return lasting access. Start again and approve consent.' if client.refresh_token.blank?

      email = service(client).get_about(fields: 'user(emailAddress)').user&.email_address
      row = ImportDriveConnection.find_or_initialize_by(tenant_id: Current.tenant_id)
      changed_account = row.persisted? && row.account_email != email
      row.update!(refresh_token: client.refresh_token, account_email: email, connected_by_id: actor&.id, last_error: nil,
        folder_id: (changed_account ? nil : row.folder_id), folder_name: (changed_account ? nil : row.folder_name))
      row
    end

    def oauth_client
      raise Error, 'Google Drive app credentials need platform setup.' unless configured?

      Signet::OAuth2::Client.new(client_id: EnvStore.platform_fetch('GOOGLE_DRIVE_CLIENT_ID', ''),
        client_secret: EnvStore.platform_fetch('GOOGLE_DRIVE_CLIENT_SECRET', ''), scope: SCOPE,
        authorization_uri: 'https://accounts.google.com/o/oauth2/auth', token_credential_uri: 'https://oauth2.googleapis.com/token')
    end

    def service(client)
      Google::Apis::DriveV3::DriveService.new.tap do |drive|
        drive.authorization = client
        drive.client_options.open_timeout_sec = 10
        drive.client_options.read_timeout_sec = 60
        drive.request_options.retries = 1
      end
    end
  end

  def initialize(connection, drive: nil)
    raise Error, 'Workspace does not match the Drive connection.' unless Current.tenant_id.present? && connection.tenant_id == Current.tenant_id
    raise Error, 'Connect Google Drive first.' unless connection.connected?

    @connection = connection
    @drive = drive || build_drive
  end

  # Folders directly under `parent` (My Drive root by default), by name only.
  def folders(parent: 'root')
    guard { list("'#{escape(parent)}' in parents and mimeType = '#{FOLDER_MIME}' and trashed = false", 'files(id,name)').map { |f| { id: f.id, name: f.name.to_s } } }
  end

  def choose_folder!(folder_id)
    guard do
      file = @drive.get_file(folder_id.to_s, fields: 'id,name,mimeType,trashed')
      raise Error, 'That is not a folder in this Drive.' unless file.mime_type == FOLDER_MIME && !file.trashed
      @connection.update!(folder_id: file.id, folder_name: file.name.to_s.first(200), last_error: nil)
    end
  end

  def files
    raise Error, 'Choose a folder first.' unless @connection.folder_chosen?

    guard do
      rows = list("'#{escape(@connection.folder_id)}' in parents and mimeType != '#{FOLDER_MIME}' and trashed = false", 'files(id,name,size,mimeType,modifiedTime)')
      @connection.update_columns(last_listed_at: Time.current)
      rows.map { |file| row_for(file) }
    end
  end

  # Fetches the given files into the inbox. Each file is checked again against
  # Google (still in the chosen folder, not trashed, size, type, checksum) before
  # its bytes are accepted. One failure never stops the others.
  def import!(file_ids, actor:)
    raise Error, 'Choose a folder first.' unless @connection.folder_chosen?

    ids = Array(file_ids).map(&:to_s).reject(&:blank?).uniq
    raise Error, 'Select at least one file.' if ids.empty?
    raise Error, "Select up to #{MAX_PER_IMPORT} files at a time." if ids.size > MAX_PER_IMPORT

    ids.map { |id| fetch_one(id, actor) }
  end

  private

  def build_drive
    client = self.class.oauth_client
    client.refresh_token = @connection.refresh_token
    client.fetch_access_token!
    self.class.service(client)
  rescue Signet::AuthorizationError
    @connection.update_columns(last_error: 'Google no longer allows access. Reconnect Google Drive.')
    raise Error, 'Google no longer allows access. Reconnect Google Drive.'
  end

  def fetch_one(id, actor)
    meta = @drive.get_file(id, fields: 'id,name,size,mimeType,parents,trashed,md5Checksum')
    name = meta.name.to_s
    return failure(name, 'It is not in the chosen folder any more.') if meta.trashed || !Array(meta.parents).include?(@connection.folder_id)
    return failure(name, 'Google documents are not converted. Download it as CSV or Excel into the folder first.') if meta.mime_type.to_s.start_with?(NATIVE_PREFIX)
    return failure(name, "Unsupported file type. Send #{Uploads::Limits::FORMATS.keys.to_sentence(last_word_connector: ', or ')}.") unless Uploads::Limits::FORMATS.key?(File.extname(name).downcase)
    return failure(name, "The file is larger than #{Uploads::Limits.human_max}.") if meta.size.to_i > Uploads::Limits::MAX_FILE_BYTES

    io = StringIO.new
    @drive.get_file(id, download_dest: io)
    bytes = io.string.b
    return failure(name, 'The download did not match Google’s checksum. Try again.') if meta.md5_checksum.present? && Digest::MD5.hexdigest(bytes) != meta.md5_checksum

    result = Uploads::Intake.call(StringIO.new(bytes), filename: name, origin: 'drive', actor: actor)
    Fetched.new(name: name, upload: result.upload, created: result.created)
  rescue Google::Apis::Error, Signet::AuthorizationError, Uploads::Intake::Error => e
    failure(meta&.name || id, e.is_a?(Uploads::Intake::Error) ? e.message : 'Google could not provide that file.')
  end

  def failure(name, message) = Fetched.new(name: name.to_s, error: message)

  def row_for(file)
    name = file.name.to_s
    native = file.mime_type.to_s.start_with?(NATIVE_PREFIX)
    supported = Uploads::Limits::FORMATS.key?(File.extname(name).downcase)
    too_big = file.size.to_i > Uploads::Limits::MAX_FILE_BYTES
    note = if native then 'Google document: download it as CSV or Excel into the folder.'
    elsif !supported then 'Unsupported type.'
    elsif too_big then "Larger than #{Uploads::Limits.human_max}."
    end
    FileRow.new(id: file.id, name: name, size: file.size&.to_i, modified_at: file.modified_time, importable: note.nil?, note: note)
  end

  def list(query, fields)
    files = []
    token = nil
    loop do
      page = @drive.list_files(q: query, fields: "nextPageToken,#{fields}", page_size: 100, page_token: token, order_by: 'modifiedTime desc')
      files.concat(Array(page.files))
      token = page.next_page_token
      break if token.blank? || files.size >= MAX_LISTED
    end
    files.first(MAX_LISTED)
  end

  def escape(value) = value.to_s.gsub(/[\\']/) { |c| "\\#{c}" }

  def guard
    yield
  rescue Google::Apis::AuthorizationError, Signet::AuthorizationError
    @connection.update_columns(last_error: 'Google no longer allows access. Reconnect Google Drive.')
    raise Error, 'Google no longer allows access. Reconnect Google Drive.'
  rescue Google::Apis::Error
    raise Error, 'Google Drive did not answer. Try again in a moment.'
  end
end
