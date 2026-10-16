# frozen_string_literal: true

class DailyReconciliationsController < AuthenticatedController
  before_action :private_response
  before_action -> { authorize(:module, :reports_read?) }
  before_action -> { authorize(:module, :reports_write?) }, only: %i[create archive review withdraw]
  rescue_from ReconciliationEvidence::Error, with: :invalid_evidence

  def index
    if params[:correct].present?
      authorize(:module, :reports_write?)
      @correction = ReconciliationDocument.find(params[:correct])
      unless @correction.kind == 'register_control' && !@correction.metadata['withdrawn'] && !ReconciliationDocument.exists?(supersedes_id: @correction.id)
        raise ReconciliationEvidence::Error, 'This control already has a correction or withdrawal. Choose its current version.'
      end
      @evidence_values = @correction.metadata.slice('currency', 'location_id').merge('source' => @correction.source,
        'kind' => @correction.kind, 'period_from' => @correction.period_from.iso8601, 'period_to' => @correction.period_to.iso8601,
        'supersedes_id' => @correction.id)
    elsif params[:request].present?
      authorize(:module, :reports_write?)
      @request = ReconciliationFollowUp.find(params[:request])
      @evidence_values = @request.attributes.slice('source', 'period_from', 'period_to', 'currency', 'location_id').merge('kind' => @request.document_kind)
    end
    load_page(@correction&.period_from&.iso8601 || @request&.period_from&.iso8601 || selected_day)
    if params[:control_for].present?
      row = @report.register.rows.find { |item| @attention.control_key(item) == params[:control_for] }
      if row && ReconciliationDocument::SOURCES.include?(row[:source])
        @evidence_values = { 'source' => row[:source], 'kind' => 'register_control', 'currency' => row[:currency], 'location_id' => row[:location_id],
          'period_from' => @report.day.iso8601, 'period_to' => @report.day.iso8601 }
      end
    end
    respond_to do |format|
      format.html
      format.csv { send_data(@report.csv, type: 'text/csv', filename: "daily-reconciliation-#{@report.day}.csv") }
    end
  end

  def create
    @request = ReconciliationFollowUp.find(params[:request_id]) if params[:request_id].present?
    @evidence_values = params.fetch(:evidence, ActionController::Parameters.new).permit(:source, :kind, :period_from, :period_to, :currency, :location_id, :note, :supersedes_id, *ReconciliationEvidence::AMOUNTS).to_h
    file = params[:file]
    raise ReconciliationEvidence::Error, 'Attach a document no larger than 8 MiB.' unless file.is_a?(ActionDispatch::Http::UploadedFile) && file.size <= ReconciliationEvidence::MAX_BYTES
    values = @evidence_values
    if values['source'] == 'rupert' || %w[daily_archive period_archive].include?(values['kind'])
      raise ReconciliationEvidence::Error, 'Use the report archive action to retain generated Rupert reports.'
    end
    context = values['supersedes_id'].present? ? ReconciliationDocument.find(values['supersedes_id']).metadata.slice('merchant', 'api_origin', 'report_kind') : {}
    metadata = context.merge(values.slice('currency', 'location_id', 'note').transform_values(&:strip))
    raise ReconciliationEvidence::Error, 'Notes must be no longer than 4000 characters.' if metadata['note'].to_s.length > 4000
    ReconciliationEvidence::AMOUNTS.each { |key| metadata[key] = ReconciliationEvidence.cents(values[key]) }
    doc = ReconciliationEvidence.retain!(bytes: file.read(ReconciliationEvidence::MAX_BYTES + 1), filename: file.original_filename,
      source: values['source'], kind: values['kind'], from: values['period_from'], to: values['period_to'], metadata: metadata,
      actor: Current.user, supersedes_id: values['supersedes_id'])
    if @request
      redirect_to reconciliation_follow_up_path(@request), notice: "Evidence ##{doc.id} retained. Select matching evidence and save your progress note to link it to this follow-up."
    else
      redirect_to daily_reconciliations_path(day: doc.period_from.iso8601), notice: "Evidence ##{doc.id} retained with its original bytes and checksum."
    end
  end

  def document
    doc = ReconciliationDocument.find(params[:id])
    send_data(doc.original_bytes, type: doc.content_type, filename: doc.filename, disposition: 'attachment')
  end

  def native_document
    receipt = case params[:source]
    when 'swipesimple' then SwipesimpleExport.find(params[:id])
    when 'authorize_net' then AuthorizeNetPortalExport.find(params[:id])
    else raise ActiveRecord::RecordNotFound
    end
    send_data(receipt.original_csv, type: 'text/csv', disposition: 'attachment', filename: "#{params[:source]}-#{receipt.id}.csv")
  end

  def archive
    report = DailyMoneyReconciliation.new(day: selected_day)
    doc = report.archive!(actor: Current.user)
    redirect_to daily_reconciliations_path(day: report.day.iso8601), notice: "Daily report archived as evidence ##{doc.id}."
  end

  def withdraw
    @withdraw_values = params.permit(:evidence_id, :reason).to_h
    previous = ReconciliationDocument.find(params[:evidence_id])
    @return_day = previous.period_from.iso8601
    reason = params[:reason].to_s.strip
    unless previous.kind == 'register_control' && !previous.metadata['withdrawn'] && reason.length.between?(1, 4000)
      raise ReconciliationEvidence::Error, 'Choose a register control and explain why it should be withdrawn.'
    end
    ReconciliationEvidence.retain!(bytes: previous.original_bytes, filename: previous.filename, source: previous.source,
      kind: previous.kind, from: previous.period_from.iso8601, to: previous.period_to.iso8601,
      metadata: previous.metadata.merge('withdrawn' => true, 'note' => reason), supersedes_id: previous.id, actor: Current.user)
    redirect_to daily_reconciliations_path(day: previous.period_from.iso8601), notice: 'Control withdrawn from comparisons; original evidence and explanation retained.'
  end

  def review
    @review_values = params.permit(:status, :notes).to_h
    report = DailyMoneyReconciliation.new(day: selected_day)
    raise ReconciliationEvidence::Error, 'The report changed. Reload it before recording your review.' unless params[:report_digest] == report.digest
    DailyReconciliationReview.create!(day: report.day, report_digest: report.digest, status: params[:status], notes: params[:notes], reviewed_by: Current.user)
    redirect_to daily_reconciliations_path(day: report.day.iso8601), notice: 'Review recorded against this report version. Source data was not changed.'
  rescue ActiveRecord::RecordInvalid
    raise ReconciliationEvidence::Error, 'Choose a review status and enter notes of 1 to 4000 characters.'
  end

  private

  def load_page(day)
    @report = DailyMoneyReconciliation.new(day: day)
    @attention = ReconciliationAttention.new(@report)
    @comparison_filter = %w[attention all matched variances unavailable conflicts].include?(params[:comparison]) ? params[:comparison] : 'attention'
    selected_status = { 'matched' => 'Matched recorded total', 'variances' => 'Variance', 'unavailable' => 'Unavailable in canonical records', 'conflicts' => 'Conflicting controls' }[@comparison_filter]
    @comparison_rows = @report.comparisons.select { |row| @comparison_filter == 'all' || (selected_status ? row[:status] == selected_status : row[:status] != 'Matched recorded total') }
    @comparison_rows = @comparison_rows.sort_by { |row| ReconciliationAttention.sort_key(row) }
    @day_follow_ups = ReconciliationFollowUp.covering(@report.day).active.includes(:owner).order(:due_on, :id).limit(6)
    @follow_up_open_count = ReconciliationFollowUp.active.count
    @follow_up_overdue_count = ReconciliationFollowUp.active.where('due_on < ?', Date.current).count
    @locations = Location.select(:id, :name, :source).order(:name).to_a
    @locations_by_id = @locations.index_by(&:id)
    @successors = ReconciliationDocument.where(supersedes_id: @report.documents.map(&:id)).select(:id, :supersedes_id, :metadata_json, :period_from).index_by(&:supersedes_id)
    @drive_connection = RetentionDriveConnection.first
    @drive_copies = @drive_connection ? RetentionDriveItem.where(generation: @drive_connection.generation, item_key: @report.documents.map { |doc| "document:#{doc.id}" }).index_by(&:item_key) : {}
    @drive_verified = @drive_connection ? RetentionDriveItem.where(generation: @drive_connection.generation, status: 'verified').where.not('item_key LIKE ?', 'folder:%').count : 0
    @archives = ReconciliationDocument.covering(@report.day).where(kind: 'daily_archive').select(:id, :created_at, :metadata_json).order(id: :desc).limit(20)
    @reviews = DailyReconciliationReview.where(day: @report.day).includes(:reviewed_by).order(id: :desc).limit(20)
    # Existing native exports remain available without copying or reinterpreting them.
    @swipesimple_exports = SwipesimpleExport.select(:id, :kind, :exported_at).order(id: :desc).limit(20)
    @authorize_exports = AuthorizeNetPortalExport.select(:id, :kind, :exported_at).order(id: :desc).limit(20)
  end

  def selected_day
    params[:day].presence || Date.current.iso8601
  end

  def private_response
    response.headers['Cache-Control'] = 'no-store'
    response.headers['X-Content-Type-Options'] = 'nosniff'
  end

  def invalid_evidence(error)
    day = safe_return_day
    if %w[create review withdraw].include?(action_name)
      @form_error = error.message
      @error_section = { 'create' => 'upload-document', 'review' => 'review-history', 'withdraw' => 'withdraw-control' }.fetch(action_name)
      load_page(day)
      render :index, status: :unprocessable_entity
    else
      redirect_to daily_reconciliations_path(day: day), alert: error.message
    end
  end

  def safe_return_day
    candidates = [@correction&.period_from&.iso8601, @request&.period_from&.iso8601, @return_day, @evidence_values&.dig('period_from'), params[:day], Date.current.iso8601]
    candidates.each do |value|
      next if value.blank?

      begin
        return ReconciliationEvidence.dates(value, value).first.iso8601
      rescue ReconciliationEvidence::Error
        next
      end
    end
  end
end
