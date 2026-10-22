# frozen_string_literal: true

# Manual Zelle bank-statement CSV evidence. Mirrors SwipeSimple reports:
# reports.read to view; sync.write to preview, import or download originals.
class ZelleReportsController < AuthenticatedController
  prepend_before_action :private_response
  before_action :authorize_report, only: :index
  before_action :authorize_import, only: %i[preview create document]

  def index
    load_report
  rescue ArgumentError
    redirect_to(zelle_reports_path, alert: 'Choose a valid day (YYYY-MM-DD).')
  end

  def preview
    @context = import_context
    prepared = ZelleReportImporter.preview(csv_text, @context)
    @preview = prepared.summary
    @preview_token = verifier.generate({ 'tenant_id' => Current.tenant_id, 'user_id' => Current.user.id,
      'fingerprint' => prepared.fingerprint }, expires_in: 15.minutes, purpose: ZelleReportImporter::CONTRACT)
    load_report
    render :index
  rescue ZelleReportImporter::Error => e
    redirect_to(zelle_reports_path, alert: e.message)
  end

  def create
    token = verifier.verified(params[:preview_token].to_s, purpose: ZelleReportImporter::CONTRACT)
    unless token.is_a?(Hash) && token['tenant_id'] == Current.tenant_id && token['user_id'] == Current.user.id
      raise ZelleReportImporter::Error, 'Preview this export first. Previews expire after 15 minutes.'
    end
    receipt = ZelleReportImporter.import!(csv_text, import_context,
      expected_fingerprint: token.fetch('fingerprint'), actor: Current.user)
    redirect_to(zelle_reports_path, notice: "Zelle export ##{receipt.id} saved or already present. Original source evidence retained; entries remain unverified until reconciled.")
  rescue ZelleReportImporter::Error => e
    redirect_to(zelle_reports_path, alert: e.message)
  end

  def document
    receipt = ZelleExport.find(params[:id])
    send_data(receipt.original_csv, type: 'text/csv', disposition: 'attachment', filename: "zelle-export-#{receipt.id}.csv")
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
    Rails.application.message_verifier('zelle-bank-csv-preview')
  end

  def import_context
    params.require(:zelle_export).permit(*ZelleReportImporter::CONTEXT_KEYS).to_h
  end

  def csv_text
    file = params[:file]
    unless file.is_a?(ActionDispatch::Http::UploadedFile) && file.size <= ZelleReportImporter::MAX_BYTES
      raise ZelleReportImporter::Error, 'Attach a bank CSV export no larger than 8 MiB.'
    end
    file.read(ZelleReportImporter::MAX_BYTES + 1)
  end

  def load_report
    @report = ZelleDailyReport.new(day: params[:day].presence || Date.current.iso8601)
    @totals = @report.totals
    @entries = @report.entries.includes(:zelle_export).order(:posted_on, :id).limit(200)
    @exports = ZelleExport.order(created_at: :desc).limit(20)
    @context ||= { 'account_label' => '', 'currency' => 'USD', 'exported_at' => Time.current.iso8601 }
  end
end
