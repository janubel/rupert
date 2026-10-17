# frozen_string_literal: true

class SettingsController < AuthenticatedController
  include DriveOauthCallback
  before_action :authorize_read, only: %i[show env drive_status drive_logs backup]
  before_action :authorize_write, except: %i[show env drive_status drive_logs backup]
  before_action :authorize_super_admin, only: %i[backup restore drive_backup new_env_export env_export drive_auth drive_oauth_callback drive_disconnect drive_status drive_logs]

  def show; end

  # GET /settings/env.json — masked view of managed env keys
  def env
    render(json: {
             keys: visible_env_keys.map do |key|
               value = EnvStore.effective(key)
               {
                 key: key,
                 set: value.present?,
                 masked: value.present? ? EnvStore.mask(value) : nil,
                 source: Setting.exists?(key: key, tenant_id: EnvStore::PLATFORM_KEYS.include?(key) ? nil : Current.tenant_id) ? 'database' : 'environment'
               }
             end
           })
  end

  # POST /settings/env_preview — JSON { text: }: what an import WOULD change,
  # without writing anything. Lets the admin confirm before applying.
  def env_preview
    text = params[:text].presence || (params[:file].read if params[:file].present?)
    raise ArgumentError, 'Provide .env text or a file' if text.blank?

    reject_unauthorized_platform_keys!(text)
    known = EnvStore.parse(text).keys & visible_env_keys
    changes = known.map { |key| preview_entry(key) }
    render(json: {
             keys: changes,
             added: changes.count { |c| !c[:currently_set] },
             updated: changes.count { |c| c[:currently_set] },
             unknown: EnvStore.parse(text).keys - EnvStore::MANAGED_KEYS
           })
  rescue ArgumentError => e
    render(json: { error: e.message }, status: :unprocessable_entity)
  end

  # POST /settings/env_import — JSON { text: } or multipart .env upload
  def env_import
    text = if params[:text].present?
      params[:text]
    elsif params[:file].present?
      params[:file].read
           end
    raise ArgumentError, 'Provide .env text or a file' if text.blank?

    imported = EnvStore.import!(text, allow_platform: platform_admin?)
    ActivityLogger.log('settings_env_imported', details: "keys: #{Array(imported.try(:keys) || imported).join(', ')}".truncate(500))
    render(json: { ok: true, imported: imported })
  rescue ArgumentError, ActiveRecord::RecordInvalid => e
    render(json: { ok: false, error: e.message }, status: :unprocessable_entity)
  end

  # GET /settings/env_export — confirmation page (the download itself is POST)
  def new_env_export; end

  # POST /settings/env_export — raw .env text of managed keys. Requires the
  # user's password again so an unlocked browser can't silently exfiltrate
  # secrets, and POST (not GET) keeps it out of caches/logs.
  def env_export
    unless Current.user.authenticate(params[:password].to_s)
      ActivityLogger.log('settings_env_export_denied', details: 'Incorrect password')
      return redirect_to(env_export_confirm_settings_path, alert: 'Password incorrect.')
    end

    ActivityLogger.log('settings_env_exported', details: 'Managed settings exported after password re-entry')
    body = EnvStore.export.map { |key, value| "#{key}=#{value}" }.join("\n") + "\n"
    render(plain: body, content_type: 'text/plain')
  end

  # GET /settings/backup — consistent SQLite snapshot download
  def backup
    path = BackupService.snapshot_path
    ActivityLogger.log('database_backup_downloaded', details: 'Full database snapshot downloaded')
    send_file(
      path,
      filename: "rupert-backup-#{Time.now.strftime('%Y%m%d-%H%M%S')}.sqlite3",
      type: 'application/octet-stream'
    )
  end

  # POST /settings/restore — upload a .sqlite3 backup and swap it in
  def restore
    file = params[:file]
    raise ArgumentError, 'No file uploaded' if file.nil?

    path = file.tempfile.path
    BackupService.restore!(path)
    ActivityLogger.log('database_restored', details: "Database replaced from upload #{file.original_filename.to_s.truncate(80)} (#{file.size} bytes)")
    render(json: { ok: true })
  rescue BackupService::RestoreError, ArgumentError => e
    render(json: { ok: false, error: e.message }, status: :unprocessable_entity)
  end

  # GET /settings/drive_status — connection state + last run (JSON)
  def drive_status
    render(json: GoogleDriveBackupService.status)
  end

  # GET /settings/drive_logs — recent backup attempts (JSON)
  def drive_logs
    rows = BackupLog.unscoped.where(tenant_id: nil).order(startedAt: :desc).limit(10).map do |log|
      {
        status: log.status,
        fileName: log.fileName,
        driveUrl: log.driveUrl,
        startedAt: log.startedAt,
        finishedLabel: log.finishedAt&.utc&.strftime('%b %e %H:%M UTC'),
        error: log.error
      }
    end
    render(json: rows)
  end

  # GET /settings/drive_auth — send the user to Google's consent screen
  def drive_auth
    state = "drive:#{SecureRandom.hex(24)}"
    session[:drive_oauth_state] = state
    session[:drive_oauth_actor_id] = Current.user.id
    session[:drive_oauth_tenant_id] = Current.tenant_id
    session[:drive_oauth_started_at] = Time.current.to_i
    redirect_to(
      GoogleDriveBackupService.auth_url(redirect_uri: google_callback_url, state: state),
      allow_other_host: true
    )
  rescue GoogleDriveBackupService::NotConfiguredError => e
    redirect_to(settings_path, alert: e.message)
  end

  # GET /settings/drive_oauth_callback — exchange the code, store refresh token
  def drive_oauth_callback
    complete_drive_oauth
  end

  # POST /settings/drive_backup — run a backup right now
  def drive_backup
    log = GoogleDriveBackupService.backup!(actor: 'user')
    ActivityLogger.log('drive_backup_run', details: "Manual Drive backup: #{log.status}")
    render(json: {
             ok: log.success?, status: log.status, fileName: log.fileName, driveUrl: log.driveUrl, error: log.error
           })
  rescue GoogleDriveBackupService::NotConnectedError => e
    render(json: { ok: false, error: e.message }, status: :unprocessable_entity)
  end

  # POST /settings/drive_disconnect — forget the refresh token
  def drive_disconnect
    GoogleDriveBackupService.disconnect!
    ActivityLogger.log('drive_disconnected', details: 'Google Drive instance backup disconnected')
    clear_drive_oauth_state
    redirect_to(settings_path, notice: 'Disconnected from Google Drive.')
  end

  # POST /settings/oauth_credentials — save Google sign-in client id/secret
  def oauth_credentials
    EnvStore.set('GOOGLE_OAUTH_CLIENT_ID', params[:client_id].to_s.strip) if params.key?(:client_id)
    secret = params[:client_secret].to_s.strip
    if params[:clear_client_secret] == '1'
      EnvStore.set('GOOGLE_OAUTH_CLIENT_SECRET', nil)
    elsif secret.present?
      EnvStore.set('GOOGLE_OAUTH_CLIENT_SECRET', secret)
    end
    changed = [params.key?(:client_id) && 'client id', (secret.present? || params[:clear_client_secret] == '1') && (params[:clear_client_secret] == '1' ? 'secret cleared' : 'secret replaced')].select(&:itself)
    ActivityLogger.log('google_signin_credentials_saved', details: changed.join(', ').presence || 'no change')
    redirect_to(settings_path, notice: 'Google sign-in credentials saved.')
  end

  # POST /settings/oauth_domains — allow a new email domain to sign in
  def oauth_domains
    domain = OauthAllowedDomain.new(domain: params[:domain], tenant_id: Current.tenant_id)
    if domain.save
      ActivityLogger.log('oauth_domain_allowed', details: domain.domain)
      redirect_to(settings_path, notice: "Allowed #{domain.domain} to sign in with Google.")
    else
      redirect_to(settings_path, alert: domain.errors.full_messages.to_sentence)
    end
  end

  # DELETE /settings/oauth_domains — revoke a domain from Google sign-in
  def oauth_remove_domain
    domain = OauthAllowedDomain.find_by(tenant_id: Current.tenant_id,
      domain: params[:domain].to_s.downcase.strip.sub(
        /\A@/, ''
      ))
    if domain&.destroy
      ActivityLogger.log('oauth_domain_removed', details: domain.domain)
      redirect_to(settings_path, notice: "Removed #{domain.domain} from Google sign-in.")
    else
      redirect_to(settings_path, alert: 'Domain not found.')
    end
  end

  # POST /settings/tenant — update business settings (name, invoice prefix,
  # low-stock threshold).
  def tenant
    TenantSettings.set(:business_name, params[:business_name]) if params[:business_name].present?
    TenantSettings.set(:invoice_prefix, params[:invoice_prefix]) if params[:invoice_prefix].present?
    TenantSettings.set(:low_stock_threshold, params[:low_stock_threshold].to_i) if params[:low_stock_threshold].present?
    ActivityLogger.log('business_settings_saved', details: %w[business_name invoice_prefix low_stock_threshold].select { |k| params[k].present? }.join(', '))
    redirect_to(settings_path, notice: 'Business settings saved.')
  end

  # POST /settings/fulfillment_workflow — enable/disable the office fulfillment
  # status workflow on orders.
  def fulfillment_workflow
    FeatureFlag.set(:fulfillment_workflow, params[:enabled] == '1')
    ActivityLogger.log('fulfillment_workflow_changed', details: params[:enabled] == '1' ? 'enabled' : 'disabled')
    redirect_to(settings_path, notice: "Fulfillment workflow #{params[:enabled] == '1' ? 'enabled' : 'disabled'}.")
  end

  # POST /settings/buzz_generate — create (or replace) the Rupert agent keypair
  def buzz_generate
    BuzzAgent.generate_keypair!
    redirect_to(settings_path, notice: "Buzz agent keypair generated — #{BuzzAgent.agent_npub}")
  rescue StandardError => e
    redirect_to(settings_path, alert: "Could not generate keypair: #{e.message}")
  end

  # POST /settings/buzz_register — publish the agent's kind 0 profile so Buzz
  # recognizes the identity and it can be added as a channel member.
  def buzz_register
    ok, message = BuzzAgent.register!
    if ok
      redirect_to settings_path, notice: "Agent profile published to Buzz — #{BuzzAgent.agent_npub}"
    else
      redirect_to settings_path, alert: "Could not publish profile: #{message}"
    end
  end

  # POST /settings/buzz_test — publish a test message to Buzz
  def buzz_test
    ok, message = BuzzAgent.notify("Test message from the Rupert agent (#{Time.current.strftime('%b %e %H:%M')})")
    if ok
      redirect_to(settings_path, notice: "Buzz test sent: #{message}")
    else
      redirect_to(settings_path, alert: "Buzz test failed: #{message}")
    end
  end

  private

  def preview_entry(key)
    current = EnvStore.effective(key)
    {
      key: key,
      currently_set: current.present?,
      from_env_file: !Setting.exists?(key: key, tenant_id: EnvStore::PLATFORM_KEYS.include?(key) ? nil : Current.tenant_id) && current.present?
    }
  end

  def authorize_read
    authorize(:module, :settings_read?)
  end

  def authorize_write
    authorize(:module, :settings_write?)
  end

  def platform_admin?
    User.find_by(id: Current.user&.id, active: true)&.super_admin? || false
  end

  def visible_env_keys
    platform_admin? ? EnvStore::MANAGED_KEYS : EnvStore::MANAGED_KEYS - EnvStore::PLATFORM_KEYS
  end

  def reject_unauthorized_platform_keys!(text)
    return if platform_admin? || (EnvStore.parse(text).keys & EnvStore::PLATFORM_KEYS).empty?

    raise ArgumentError, 'Google Drive instance backup settings require a platform super administrator'
  end

  def authorize_super_admin
    redirect_to(settings_path, alert: 'Only the super admin can do that.') unless platform_admin?
  end
end
