# frozen_string_literal: true

# Completes the read-only Google Drive consent started from the Uploads page.
# Bound to the person, workspace and a ten-minute state, like the retention link.
module UploadsDriveOauthCallback
  private

  def complete_uploads_drive_oauth
    intent = session.delete(:uploads_drive_oauth)&.symbolize_keys
    unless Current.user&.active? && Current.tenant&.status == 'active' && Current.user.can?('uploads.write') && Current.user.can?('settings.write') &&
        intent && intent[:state] == params[:state] && intent[:actor] == Current.user.id && intent[:tenant] == Current.tenant_id &&
        intent[:started_at].to_i.between?(10.minutes.ago.to_i, Time.current.to_i)
      return redirect_to(login_path, alert: 'Drive connection could not be verified. Sign in and start again from Uploads.')
    end
    return redirect_to(uploads_drive_path, alert: 'Google Drive consent was declined. Nothing was connected.') if params[:error].present?
    return redirect_to(uploads_drive_path, alert: 'Google did not return authorization. Start the connection again.') if params[:code].blank?

    DriveSource.exchange_code!(params[:code], redirect_uri: google_callback_url, actor: Current.user)
    ActivityLogger.log('uploads_drive_connected', details: 'Read-only Google Drive connected for the Uploads inbox')
    redirect_to uploads_drive_path, notice: 'Google Drive connected (read-only). Choose the folder Rupert may read.'
  rescue DriveSource::Error, Signet::AuthorizationError, Google::Apis::Error
    redirect_to uploads_drive_path, alert: 'Google Drive could not be connected. Check Google app access and try again.'
  end
end
