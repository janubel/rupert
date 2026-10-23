# frozen_string_literal: true

require 'google/apis/drive_v3'
require 'signet/oauth_2/client'
require 'fileutils'
require 'digest'
require 'tempfile'

# Whole-instance Google Drive backup, configured only by the platform operator.
# Tenant-owned Drive settings are never trusted as a snapshot destination.
# Backups are a consistent DB snapshot (SQLite VACUUM INTO), uploaded to the
# owner's Drive with no external sharing, pruned to the retention window, and
# every attempt is recorded in the BackupLog table for verification.
class GoogleDriveBackupService
  class NotConfiguredError < StandardError; end
  class NotConnectedError < StandardError; end
  # A NotConnectedError, so every caller that handles "not connected" also stops here.
  class DomainNotAllowedError < NotConnectedError; end

  SCOPE = 'https://www.googleapis.com/auth/drive.file'
  DEFAULT_RETENTION = 7
  FOLDER_NAME = 'Rupert Backups'

  class << self
    def configured?
      client_id.present? && client_secret.present?
    end

    def connected?
      configured? && EnvStore.platform_fetch('GOOGLE_DRIVE_REFRESH_TOKEN', '').present?
    end

    # Backups may only go to a Google account in this Workspace domain (e.g.
    # "example.com"). Blank means no restriction has been set yet.
    def allowed_domain
      normalize_domain(EnvStore.platform_fetch('GOOGLE_DRIVE_ALLOWED_DOMAIN', ''))
    end

    def allowed_domain=(value)
      domain = normalize_domain(value)
      if domain.present? && !domain.match?(/\A[a-z0-9-]+(\.[a-z0-9-]+)+\z/)
        raise ArgumentError, 'Enter a domain such as example.com'
      end

      EnvStore.platform_set('GOOGLE_DRIVE_ALLOWED_DOMAIN', domain)
    end

    # The Google account the saved token belongs to, recorded at connect time.
    def account_email
      EnvStore.platform_fetch('GOOGLE_DRIVE_ACCOUNT_EMAIL', '').to_s
    end

    def email_allowed?(email)
      domain = allowed_domain
      return true if domain.blank?

      email.to_s.downcase.split('@', 2).last == domain
    end

    # True when a connection exists but its account is outside the allowed domain
    # (or was connected before the account was recorded).
    def wrong_account?
      connected? && allowed_domain.present? && !email_allowed?(account_email)
    end

    def auth_url(redirect_uri:, state: nil)
      require_credentials!
      client = signet
      client.redirect_uri = redirect_uri
      params = { access_type: 'offline', prompt: 'consent' }
      # hd pre-selects the Workspace domain on Google's account chooser; the
      # account is still checked server-side after the code exchange.
      params[:hd] = allowed_domain if allowed_domain.present?
      params[:state] = state if state.present?
      client.authorization_uri(params).to_s
    end

    def exchange_code!(code, redirect_uri:)
      require_credentials!
      client = signet
      client.redirect_uri = redirect_uri
      client.code = code
      client.fetch_access_token!
      if client.refresh_token.blank?
        raise NotConnectedError, 'Google did not return a refresh token — try disconnecting and reconnecting'
      end

      email = account_email_for(client)
      unless email.present? && email_allowed?(email)
        revoke(client.refresh_token)
        raise DomainNotAllowedError,
          "Backups can only go to a Google account in #{allowed_domain}. #{email.presence || 'That account'} was not connected."
      end

      EnvStore.platform_set('GOOGLE_DRIVE_REFRESH_TOKEN', client.refresh_token)
      EnvStore.platform_set('GOOGLE_DRIVE_ACCOUNT_EMAIL', email)
    end

    # Snapshot + upload + verified download + prune. Returns the BackupLog record.
    def backup!(actor: 'manual')
      Current.set(tenant: nil) do
        SyncObservability.observe('google_backup', 'backup') { perform_backup!(actor: actor) }
      end
    end

    def perform_backup!(actor:)
      raise NotConnectedError, 'Google Drive is not connected' unless connected?
      if wrong_account?
        raise DomainNotAllowedError,
          "The connected Google account is outside #{allowed_domain}. Disconnect and connect an account in #{allowed_domain}."
      end

      log = Current.set(tenant: nil) { BackupLog.create!(status: 'running', startedAt: Time.current, tenant_id: nil) }
      path = nil
      begin
        path = BackupService.snapshot_path
        filename = "rupert-backup-#{Time.current.strftime('%Y%m%d-%H%M%S')}#{File.extname(path)}"

        drive = drive_service
        folder_id = ensure_folder!(drive)
        metadata = Google::Apis::DriveV3::File.new(
          name: filename, parents: [folder_id], mime_type: 'application/octet-stream'
        )
        file = drive.create_file(
          metadata,
          upload_source: path,
          content_type: 'application/octet-stream'
        )

        verify_upload!(drive, file.id, path)
        prune_old!(drive, folder_id)

        log.update!(
          status: 'success',
          finishedAt: Time.current,
          fileName: filename,
          fileSize: File.size(path),
          driveFileId: file.id,
          driveUrl: "https://drive.google.com/file/d/#{file.id}/view"
        )
      rescue StandardError => e
        log.update!(
          status: 'failed',
          finishedAt: Time.current,
          error: e.message.to_s[0, 2000]
        )
        raise
      ensure
        FileUtils.rm_f(path) if path
      end
      log
    end

    def status
      logs = BackupLog.unscoped.where(tenant_id: nil)
      last = logs.order(startedAt: :desc).first
      latest_ok = logs.where(status: 'success').order(startedAt: :desc).first
      {
        configured: configured?,
        connected: connected?,
        retention: retention,
        folder_id: EnvStore.platform_fetch('GOOGLE_DRIVE_FOLDER_ID', ''),
        client_id_set: EnvStore.platform_fetch('GOOGLE_DRIVE_CLIENT_ID', '').present?,
        client_secret_set: EnvStore.platform_fetch('GOOGLE_DRIVE_CLIENT_SECRET', '').present?,
        refresh_token_set: EnvStore.platform_fetch('GOOGLE_DRIVE_REFRESH_TOKEN', '').present?,
        account_email: account_email.presence,
        allowed_domain: allowed_domain.presence,
        wrong_account: wrong_account?,
        last: last && {
          status: last.status,
          startedAt: last.startedAt,
          finishedAt: last.finishedAt,
          fileName: last.fileName,
          driveUrl: last.driveUrl,
          error: last.error
        },
        latest_drive_url: latest_ok&.driveUrl
      }
    end

    def disconnect!
      # A blank platform override also disables a token supplied by host ENV.
      EnvStore.platform_set('GOOGLE_DRIVE_REFRESH_TOKEN', '')
      EnvStore.platform_set('GOOGLE_DRIVE_ACCOUNT_EMAIL', '')
    end

    def retention
      value = EnvStore.platform_fetch('GOOGLE_DRIVE_RETENTION', DEFAULT_RETENTION.to_s).to_i
      value.positive? ? value : DEFAULT_RETENTION
    end

    private

    def verify_upload!(drive, file_id, path)
      metadata = drive.get_file(file_id, fields: 'id,size,md5Checksum')
      unless metadata.size.to_i == File.size(path) && metadata.md5_checksum == Digest::MD5.file(path).hexdigest
        raise NotConnectedError, 'Google Drive upload verification failed (size or checksum).'
      end
      Tempfile.create(['rupert-backup-verify-', '.bin']) do |copy|
        copy.chmod(0o600)
        drive.get_file(file_id, download_dest: copy.path)
        unless File.size(copy.path) == File.size(path) &&
            Digest::SHA256.file(copy.path).hexdigest == Digest::SHA256.file(path).hexdigest
          raise NotConnectedError, 'Google Drive downloaded backup did not match the database snapshot.'
        end
      end
    end

    def normalize_domain(value)
      value.to_s.strip.downcase.delete_prefix('@').presence.to_s
    end

    # Asks Drive who the token belongs to. Works with the drive.file scope.
    def account_email_for(client)
      service = Google::Apis::DriveV3::DriveService.new
      service.authorization = client
      service.get_about(fields: 'user(emailAddress)')&.user&.email_address.to_s.downcase
    rescue Google::Apis::Error, Signet::AuthorizationError
      ''
    end

    def revoke(token)
      Net::HTTP.post_form(URI('https://oauth2.googleapis.com/revoke'), token: token)
    rescue StandardError
      nil
    end

    def require_credentials!
      raise NotConfiguredError, 'GOOGLE_DRIVE_CLIENT_ID / CLIENT_SECRET are not set' unless configured?
    end

    def client_id
      EnvStore.platform_fetch('GOOGLE_DRIVE_CLIENT_ID', '')
    end

    def client_secret
      EnvStore.platform_fetch('GOOGLE_DRIVE_CLIENT_SECRET', '')
    end

    def signet
      Signet::OAuth2::Client.new(
        client_id: client_id,
        client_secret: client_secret,
        scope: SCOPE,
        authorization_uri: 'https://accounts.google.com/o/oauth2/auth',
        token_credential_uri: 'https://oauth2.googleapis.com/token'
      )
    end

    def drive_service
      refresh = EnvStore.platform_fetch('GOOGLE_DRIVE_REFRESH_TOKEN', '')
      raise NotConnectedError, 'Google Drive is not connected' if refresh.blank?

      client = signet
      client.refresh_token = refresh
      client.fetch_access_token! if client.expired?

      service = Google::Apis::DriveV3::DriveService.new
      service.authorization = client
      service
    end

    def ensure_folder!(drive)
      existing = EnvStore.platform_fetch('GOOGLE_DRIVE_FOLDER_ID', '')
      return existing if existing.present?

      query = "name='#{FOLDER_NAME}' and mimeType='application/vnd.google-apps.folder' and trashed=false"
      results = drive.list_files(q: query, fields: 'files(id)', page_size: 1)
      folder = if results.files.any?
        results.files.first
      else
        drive.create_file(Google::Apis::DriveV3::File.new(
          name: FOLDER_NAME, mime_type: 'application/vnd.google-apps.folder'
        ))
               end
      EnvStore.platform_set('GOOGLE_DRIVE_FOLDER_ID', folder.id)
      folder.id
    end

    def prune_old!(drive, folder_id)
      files = drive.list_files(
        q: "'#{folder_id}' in parents and trashed=false",
        fields: 'files(id,createdTime)',
        page_size: 100,
        order_by: 'createdTime desc'
      ).files
      files.drop(retention).each { |file| drive.delete_file(file.id) }
    end
  end
end
