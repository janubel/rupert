# frozen_string_literal: true

module DriveOauthCallback
  private

  def complete_drive_oauth
    unless Current.user&.active? && Current.user.super_admin? &&
        Current.user.tenant&.status == 'active' && Current.tenant&.status == 'active'
      clear_drive_oauth_state
      return redirect_to(login_path, alert: 'Sign in as the platform administrator to connect backups.')
    end
    state = session[:drive_oauth_state]
    valid = state.present? && state == params[:state] &&
      session[:drive_oauth_actor_id] == Current.user.id &&
      session[:drive_oauth_tenant_id] == Current.tenant_id &&
      session[:drive_oauth_started_at].to_i.between?(10.minutes.ago.to_i, Time.current.to_i)
    clear_drive_oauth_state
    return redirect_to(settings_path, alert: 'Google Drive authorization failed state check. Try again.') unless valid
    return redirect_to(settings_path, alert: 'Google Drive authorization was declined.') if params[:error].present?
    return redirect_to(settings_path, alert: 'Google Drive did not return an authorization code.') if params[:code].blank?

    GoogleDriveBackupService.exchange_code!(params[:code], redirect_uri: google_callback_url)
    ActivityLogger.log('drive_connected', details: "Google Drive backup connected as #{GoogleDriveBackupService.account_email}")
    redirect_to(settings_path, notice: "Connected to Google Drive as #{GoogleDriveBackupService.account_email}.")
  rescue GoogleDriveBackupService::DomainNotAllowedError => e
    ActivityLogger.log('drive_connect_refused', details: e.message)
    redirect_to(settings_path, alert: e.message)
  rescue GoogleDriveBackupService::NotConfiguredError,
         GoogleDriveBackupService::NotConnectedError, Signet::AuthorizationError
    redirect_to(settings_path, alert: 'Google Drive could not be connected. Please try again.')
  end

  def clear_drive_oauth_state
    %i[drive_oauth_state drive_oauth_actor_id drive_oauth_tenant_id drive_oauth_started_at].each do |key|
      session.delete(key)
    end
  end
end
