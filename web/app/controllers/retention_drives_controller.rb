# frozen_string_literal: true

class RetentionDrivesController < AuthenticatedController
  before_action -> { authorize(:module, :reports_read?) }
  before_action -> { authorize(:module, :reports_write?) }, except: :show
  before_action -> { authorize(:module, :settings_write?) }, only: %i[connect disconnect]
  before_action { response.headers['Cache-Control'] = 'no-store' }

  def show
    @connection = RetentionDriveConnection.first
    @items = @connection ? RetentionDriveItem.where(generation: @connection.generation).where.not('item_key LIKE ?', 'folder:%') : RetentionDriveItem.none
    @total = ReconciliationDocument.count + SwipesimpleExport.count + AuthorizeNetPortalExport.count
    @counts = @items.group(:status).count
    @recent = @items.order(updated_at: :desc).limit(30)
    @root = @connection && RetentionDriveItem.find_by(generation: @connection.generation, item_key: 'folder:root')
  end

  def connect
    state = "retention:#{SecureRandom.hex(24)}"
    session[:retention_drive_oauth] = { state: state, actor: Current.user.id, tenant: Current.tenant_id, started_at: Time.current.to_i }
    redirect_to RetentionDrive.auth_url(redirect_uri: google_callback_url, state: state), allow_other_host: true
  rescue GoogleDriveBackupService::NotConfiguredError, RetentionDrive::Error
    redirect_to retention_drive_path, alert: 'The platform administrator needs to finish Google Drive app setup first.'
  end

  def sync
    connection = RetentionDriveConnection.first
    if connection&.connected? && connection.enabled
      RetentionDriveJob.perform_later(Current.tenant_id)
      redirect_to retention_drive_path, notice: 'Sync queued. Files are marked Copied only after download and checksum verification.'
    else
      redirect_to retention_drive_path, alert: 'Connect Google Drive to start automatic retention.'
    end
  end

  def disconnect
    RetentionDriveConnection.first&.update!(refresh_token: nil, enabled: false, sync_lease_token: nil, sync_lease_at: nil)
    session.delete(:retention_drive_oauth)
    redirect_to retention_drive_path, notice: 'Automatic uploads disconnected. Existing Drive copies and Rupert originals are preserved.'
  end
end
