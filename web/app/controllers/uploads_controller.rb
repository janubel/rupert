# frozen_string_literal: true

# The Uploads inbox: one place to send any file, see what Rupert made of it, and
# decide what happens next. Receiving a file never changes a business record; an
# import runs only after a dry run and an explicit approval, by someone allowed to
# write to the destination (see Uploads::Workflow).
class UploadsController < AuthenticatedController
  FILTERS = { 'open' => Upload::OPEN_STATUSES, 'needs_review' => %w[needs_review], 'recognized' => %w[recognized], 'imported' => %w[imported],
              'rejected' => %w[rejected], 'duplicate' => %w[duplicate] }.freeze

  before_action -> { authorize(:module, :uploads_read?) }
  before_action -> { authorize(:module, :uploads_write?) }, except: %i[index show original insights]
  before_action { response.headers['Cache-Control'] = 'private, no-store' }
  before_action :load_upload, except: %i[index create recognize_all insights]
  rescue_from Uploads::Workflow::Error, Uploads::Intake::Error, with: :workflow_failed

  def index
    @filter = FILTERS.key?(params[:status]) ? params[:status] : 'all'
    scope = Upload.newest_first
    scope = scope.where(status: FILTERS.fetch(@filter)) if FILTERS.key?(@filter)
    scope = scope.where('filename LIKE ?', "%#{Upload.sanitize_sql_like(params[:q].to_s.strip.first(80))}%") if params[:q].present?
    @pagy, @uploads = pagy(scope, items: 25)
    @counts = Upload.group(:status).count
    @stale = Upload.where(status: 'needs_review', retained: true).where.not(recognizer_version: Uploads::Registry.signature).count
    @can_write = Current.user.can?('uploads.write')
  end

  # How the inbox is doing: volume, outcomes, why files wait, importer health.
  # Aggregates only; see Uploads::Insights.
  def insights
    @insights = Uploads::Insights.new(days: params[:days])
  end

  def create
    files = submitted_files
    return redirect_to(uploads_path, alert: 'Choose at least one file.') if files.empty?
    return redirect_to(uploads_path, alert: "Send up to #{Uploads::Limits::MAX_FILES_PER_REQUEST} files at a time.") if files.size > Uploads::Limits::MAX_FILES_PER_REQUEST
    if files.sum(&:size) > Uploads::Limits::MAX_REQUEST_BYTES
      return redirect_to(uploads_path, alert: "Those files add up to more than #{number_to_human_size(Uploads::Limits::MAX_REQUEST_BYTES)}. Send fewer at a time.")
    end

    results = files.map do |file|
      Uploads::Intake.call(file, filename: file.original_filename, content_type: file.content_type, origin: 'web', actor: Current.user)
    end
    respond_with_results(results)
  end

  def show
    @document = Uploads::Document.for(@upload) if @upload.retained
    @importer = @upload.importer
    @preview = Uploads::Preview.build(@document, @importer) if @document
    @choices = Uploads::Workflow.choices_for(@upload)
    @params_spec = @importer ? @importer.params_spec(@document, current_detection) : []
    @can_write = Current.user.can?('uploads.write')
    @can_import = @importer && Uploads::Workflow.allowed?(@importer, Current.user)
    @duplicate_of = @upload.duplicate_of
    @copies = Upload.where(duplicate_of_id: @upload.id).newest_first.limit(10) if @upload.retained
  end

  def choose
    key, type = params[:importer_choice].to_s.split('|', 2)
    importer = Uploads::Registry.find(key)
    Uploads::Workflow.choose!(@upload, importer_key: key, type: type, params: params[:fields] || {}, actor: Current.user)
    notice = importer ? "Using #{importer.label}. Run a dry run to see what it would do." : 'Saved.'
    redirect_to upload_path(@upload), notice: notice
  end

  def dry_run
    save_fields
    Uploads::Workflow.dry_run!(@upload, actor: Current.user)
    if @upload.reload.dry_run_current?
      redirect_to upload_path(@upload), notice: 'Dry run finished. Nothing was changed. Review the result, then approve if it is right.'
    else
      redirect_to upload_path(@upload), alert: "The dry run could not complete: #{@upload.reason}"
    end
  end

  def approve
    Uploads::Workflow.import!(@upload, actor: Current.user)
    redirect_to upload_path(@upload), notice: 'Imported. The original file is kept unchanged.'
  end

  def discard
    Uploads::Workflow.discard!(@upload, actor: Current.user)
    redirect_to uploads_path, notice: 'Discarded. The original is still kept; you can reopen it from the list.'
  end

  def reopen
    Uploads::Workflow.reopen!(@upload, actor: Current.user)
    redirect_to upload_path(@upload), notice: 'Reopened and recognized again.'
  end

  def recognize
    Uploads::Workflow.recognize!(@upload, actor: Current.user)
    redirect_to upload_path(@upload), notice: 'Looked at the file again.'
  end

  def recognize_all
    changed = Uploads::Workflow.recognize_all!(actor: Current.user)
    redirect_to uploads_path, notice: changed.zero? ? 'Looked at every open file again. None changed.' : "Looked at every open file again. #{changed} changed."
  end

  # The original, exactly as received, only ever as a download.
  def original
    raise ActiveRecord::RecordNotFound unless @upload.retained

    log_export('Upload original', "sha256=#{@upload.sha256.first(12)}")
    response.headers['X-Content-Type-Options'] = 'nosniff'
    response.headers['Content-Security-Policy'] = "default-src 'none'; sandbox"
    send_data @upload.original_bytes, type: 'application/octet-stream', disposition: 'attachment', filename: @upload.filename
  end

  private

  def load_upload
    @upload = Upload.find(params[:id])
  end

  def submitted_files
    candidates = Array(params[:files]) + Array(params[:file])
    candidates.grep(ActionDispatch::Http::UploadedFile)
  end

  def save_fields
    return unless params[:fields] && @upload.importer

    document = Uploads::Document.for(@upload)
    cleaned = Uploads::Workflow.clean_params(@upload.importer, params[:fields], document, @upload)
    @upload.update!(params_json: @upload.params.merge(cleaned).to_json)
  end

  def current_detection
    entry = @upload.candidates.find { |candidate| candidate['importer'] == @upload.importer_key && candidate['type'] == @upload.detected_type }
    entry && Uploads::Detection.new(type: entry['type'])
  end

  def respond_with_results(results)
    kept = results.count { |result| result.created }
    duplicates = results.count { |result| result.upload.status == 'duplicate' }
    refused = results.select { |result| result.upload.status == 'rejected' }
    parts = []
    parts << "#{kept} file#{'s' unless kept == 1} received" if kept.positive?
    parts << "#{duplicates} already here" if duplicates.positive?
    notice = parts.join(', ').presence
    alert = refused.map { |result| "#{result.upload.filename}: #{result.upload.reason}" }.join(' ').presence
    flash[:notice] = "#{notice}." if notice
    flash[:alert] = alert if alert
    target = results.size == 1 && !refused.any? ? upload_path(results.first.upload) : uploads_path
    redirect_to target
  end

  def workflow_failed(error)
    redirect_back fallback_location: (@upload ? upload_path(@upload) : uploads_path), alert: error.message
  end
end
