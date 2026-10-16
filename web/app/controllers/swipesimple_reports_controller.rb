# frozen_string_literal: true

class SwipesimpleReportsController < AuthenticatedController
  prepend_before_action :private_response
  before_action :authorize_report, only: :index
  before_action :authorize_import, only: %i[preview create document]

  def index
    load_report
  rescue ArgumentError
    redirect_to(swipesimple_reports_path, alert: 'Choose a valid day (YYYY-MM-DD).')
  end

  def preview
    @context = import_context
    prepared = SwipesimpleReportImporter.preview(csv_text, @context)
    @preview = prepared.summary
    @preview_token = verifier.generate({ 'tenant_id' => Current.tenant_id, 'user_id' => Current.user.id,
      'fingerprint' => prepared.fingerprint }, expires_in: 15.minutes, purpose: SwipesimpleReportImporter::CONTRACT)
    load_report
    render :index
  rescue SwipesimpleReportImporter::Error => e
    redirect_to(swipesimple_reports_path, alert: e.message)
  end

  def create
    token = verifier.verified(params[:preview_token].to_s, purpose: SwipesimpleReportImporter::CONTRACT)
    unless token.is_a?(Hash) && token['tenant_id'] == Current.tenant_id && token['user_id'] == Current.user.id
      raise SwipesimpleReportImporter::Error, 'Preview this export first. Previews expire after 15 minutes.'
    end
    receipt = SwipesimpleReportImporter.import!(csv_text, import_context,
      expected_fingerprint: token.fetch('fingerprint'), actor: Current.user)
    redirect_to(swipesimple_reports_path, notice: "SwipeSimple export ##{receipt.id} saved or already present. Original source evidence retained.")
  rescue SwipesimpleReportImporter::Error => e
    redirect_to(swipesimple_reports_path, alert: e.message)
  end

  def document
    receipt = SwipesimpleExport.find(params[:id])
    send_data(receipt.original_csv, type: 'text/csv', disposition: 'attachment',
      filename: "swipesimple-#{receipt.kind}-#{receipt.id}.csv")
  end

  private

  def private_response
    response.headers['Cache-Control'] = 'no-store'
    response.headers['X-Content-Type-Options'] = 'nosniff'
  end

  def authorize_report
    authorize(:module, :reports_read?)
  end

  def authorize_import
    authorize(:module, :sync_write?)
  end

  def verifier
    Rails.application.message_verifier('swipesimple-native-preview')
  end

  def import_context
    params.require(:swipesimple_export).permit(*SwipesimpleReportImporter::CONTEXT_KEYS).to_h
  end

  def csv_text
    file = params[:file]
    unless file.is_a?(ActionDispatch::Http::UploadedFile) && file.size <= SwipesimpleReportImporter::MAX_BYTES
      raise SwipesimpleReportImporter::Error, 'Attach a native CSV export no larger than 8 MiB.'
    end
    file.read(SwipesimpleReportImporter::MAX_BYTES + 1)
  end

  def load_report
    @report = SwipesimpleDailyReport.new(day: params[:day].presence || Date.current.iso8601)
    @totals = @report.totals
    @transactions = @report.transactions.includes(:swipesimple_export).order(occurred_at: :desc).limit(200)
    @invoices = SwipesimpleReportRow.latest.where(swipesimple_exports: { kind: 'invoices' })
      .includes(:swipesimple_export).order(occurred_at: :desc).limit(200)
    @exports = SwipesimpleExport.order(created_at: :desc).limit(20)
    @context ||= { 'kind' => 'transactions', 'merchant_account' => '', 'currency' => 'USD',
      'source_timezone' => 'America/New_York', 'exported_at' => '' }
  end
end
