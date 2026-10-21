# frozen_string_literal: true

# Google Drive as a second way into the Uploads inbox. A person connects read-only
# access, picks one folder, and chooses files to copy in. Each file then follows
# the normal inbox path (kept, recognized, dry run, approval); nothing here
# changes a business record.
class UploadsDriveController < AuthenticatedController
  before_action -> { authorize(:module, :uploads_write?) }
  before_action -> { authorize(:module, :settings_write?) }, only: %i[connect disconnect]
  before_action { response.headers['Cache-Control'] = 'private, no-store' }
  rescue_from DriveSource::Error, with: :drive_failed

  def show
    @connection = ImportDriveConnection.first
    @configured = DriveSource.configured?
    return unless @connection&.connected?

    source = DriveSource.new(@connection)
    if @connection.folder_chosen?
      @files = source.files
    else
      @folder_parent = params[:parent].presence || 'root'
      @folders = source.folders(parent: @folder_parent)
    end
  end

  def connect
    state = "uploads_drive:#{SecureRandom.hex(24)}"
    session[:uploads_drive_oauth] = { state: state, actor: Current.user.id, tenant: Current.tenant_id, started_at: Time.current.to_i }
    redirect_to DriveSource.auth_url(redirect_uri: google_callback_url, state: state), allow_other_host: true
  rescue DriveSource::Error
    session.delete(:uploads_drive_oauth)
    redirect_to uploads_drive_path, alert: 'The platform administrator needs to finish Google Drive app setup first.'
  end

  def folder
    DriveSource.new(connection!).choose_folder!(params[:folder_id])
    ActivityLogger.log('uploads_drive_folder_chosen', details: 'A Drive folder was chosen for the Uploads inbox')
    redirect_to uploads_drive_path, notice: 'Folder chosen. Rupert will list and read only this folder.'
  end

  def import
    results = DriveSource.new(connection!).import!(params[:file_ids], actor: Current.user)
    done = results.select(&:upload)
    failed = results.reject(&:upload)
    ActivityLogger.log('uploads_drive_import', details: "#{done.size} file(s) copied from Drive, #{failed.size} refused")
    notice = "Copied #{done.size} file#{'s' unless done.size == 1} into the inbox; nothing has been imported yet."
    alert = failed.map { |row| "#{row.name}: #{row.error}" }.to_sentence.presence
    redirect_to(done.size == 1 ? upload_path(done.first.upload) : uploads_path, { notice: (notice if done.any?), alert: alert }.compact)
  end

  def disconnect
    ImportDriveConnection.first&.update!(refresh_token: nil, folder_id: nil, folder_name: nil)
    ActivityLogger.log('uploads_drive_disconnected', details: 'Google Drive disconnected from the Uploads inbox')
    redirect_to uploads_drive_path, notice: 'Disconnected. Files already copied into the inbox stay there.'
  end

  private

  def connection!
    connection = ImportDriveConnection.first
    raise DriveSource::Error, 'Connect Google Drive first.' unless connection&.connected?

    connection
  end

  def drive_failed(error)
    redirect_to uploads_drive_path, alert: error.message
  end
end
