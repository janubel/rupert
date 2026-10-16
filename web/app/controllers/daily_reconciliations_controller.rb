# frozen_string_literal: true

class DailyReconciliationsController < AuthenticatedController
  before_action :private_response
  before_action -> { authorize(:module, :reports_read?) }
  before_action -> { authorize(:module, :reports_write?) }, only: %i[create archive review]
  rescue_from ReconciliationEvidence::Error, with: :invalid_evidence

  def index
    @report = DailyMoneyReconciliation.new(day: selected_day)
    @archives = ReconciliationDocument.covering(@report.day).where(kind: 'daily_archive').order(id: :desc).limit(20)
    @reviews = DailyReconciliationReview.where(day: @report.day).includes(:reviewed_by).order(id: :desc).limit(20)
    # Existing native exports remain available without copying or reinterpreting them.
    @swipesimple_exports = SwipesimpleExport.order(id: :desc).limit(20)
    @authorize_exports = AuthorizeNetPortalExport.order(id: :desc).limit(20)
    respond_to do |format|
      format.html
      format.csv { send_data(@report.csv, type: 'text/csv', filename: "daily-reconciliation-#{@report.day}.csv") }
    end
  end

  def create
    file = params[:file]
    raise ReconciliationEvidence::Error, 'Attach a document no larger than 8 MiB.' unless file.is_a?(ActionDispatch::Http::UploadedFile) && file.size <= ReconciliationEvidence::MAX_BYTES
    values = params.require(:evidence).permit(:source, :kind, :period_from, :period_to, :currency, :location_id, :note, :supersedes_id, *ReconciliationEvidence::AMOUNTS).to_h
    metadata = values.slice('currency', 'location_id', 'note').transform_values(&:strip)
    raise ReconciliationEvidence::Error, 'Notes must be no longer than 4000 characters.' if metadata['note'].to_s.length > 4000
    ReconciliationEvidence::AMOUNTS.each { |key| metadata[key] = ReconciliationEvidence.cents(values[key]) }
    doc = ReconciliationEvidence.retain!(bytes: file.read(ReconciliationEvidence::MAX_BYTES + 1), filename: file.original_filename,
      source: values['source'], kind: values['kind'], from: values['period_from'], to: values['period_to'], metadata: metadata,
      actor: Current.user, supersedes_id: values['supersedes_id'])
    redirect_to daily_reconciliations_path(day: doc.period_from.iso8601), notice: "Evidence ##{doc.id} retained with its original bytes and checksum."
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

  def review
    report = DailyMoneyReconciliation.new(day: selected_day)
    raise ReconciliationEvidence::Error, 'The report changed. Reload it before recording your review.' unless params[:report_digest] == report.digest
    DailyReconciliationReview.create!(day: report.day, report_digest: report.digest, status: params[:status], notes: params[:notes], reviewed_by: Current.user)
    redirect_to daily_reconciliations_path(day: report.day.iso8601), notice: 'Review recorded against this report version. Source data was not changed.'
  rescue ActiveRecord::RecordInvalid
    raise ReconciliationEvidence::Error, 'Choose a review status and enter notes of 1 to 4000 characters.'
  end

  private

  def selected_day
    params[:day].presence || Date.current.iso8601
  end

  def private_response
    response.headers['Cache-Control'] = 'no-store'
    response.headers['X-Content-Type-Options'] = 'nosniff'
  end

  def invalid_evidence(error)
    redirect_to daily_reconciliations_path, alert: error.message
  end
end
