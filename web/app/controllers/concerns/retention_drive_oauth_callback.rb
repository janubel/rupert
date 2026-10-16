# frozen_string_literal: true

module RetentionDriveOauthCallback
  private

  def complete_retention_drive_oauth
    intent = session.delete(:retention_drive_oauth)&.symbolize_keys
    unless Current.user&.active? && Current.tenant&.status == 'active' && Current.user.can?('reports.write') && Current.user.can?('settings.write') &&
        intent && intent[:state] == params[:state] && intent[:actor] == Current.user.id && intent[:tenant] == Current.tenant_id &&
        intent[:started_at].to_i.between?(10.minutes.ago.to_i, Time.current.to_i)
      return redirect_to(login_path, alert: 'Drive connection could not be verified. Sign in and start again from document retention.')
    end
    return redirect_to(retention_drive_path, alert: 'Google Drive consent was declined. Originals remain in Rupert.') if params[:error].present?
    return redirect_to(retention_drive_path, alert: 'Google did not return authorization. Start the connection again.') if params[:code].blank?

    RetentionDrive.exchange_code!(params[:code], redirect_uri: google_callback_url)
    RetentionDriveJob.perform_later(Current.tenant_id)
    redirect_to retention_drive_path, notice: 'Google Drive connected. Existing and new retained files will copy automatically.'
  rescue RetentionDrive::Error, Signet::AuthorizationError, Google::Apis::Error
    redirect_to retention_drive_path, alert: 'Google Drive could not be connected. Check Google app access and try again; originals remain in Rupert.'
  end
end
