# frozen_string_literal: true

class MoneyReconciliationsController < AuthenticatedController
  before_action { authorize(:module, :reports_read?) }
  before_action { response.headers['Cache-Control'] = 'private, no-store' }

  def index
    saved = MoneyReconciliation.find(params[:saved]) if params[:saved].present?
    @report = MoneyReconciliationReport.new(kind: saved&.period_kind || params[:kind].presence || 'daily',
      date: saved&.period_from || params[:date].presence || Time.find_zone!(MoneyReconciliationReport::ZONE).today)
    @payload = saved ? saved.payload : @report.payload
    @saved = saved
    @history = MoneyReconciliation.order(period_from: :desc, generated_at: :desc).limit(36)
    respond_to do |format|
      format.html { @findings = Finance::ReconciliationFindings.new }
      format.json { render json: @payload }
      format.csv {
        log_export('Money reconciliation CSV', "#{@report.kind} #{@report.from}")
        send_data @report.csv(@payload), filename: "money-reconciliation-#{@report.kind}-#{@report.from.iso8601}.csv" }
    end
  rescue ArgumentError
    redirect_to money_reconciliations_path, alert: 'Choose a valid daily, weekly, monthly, quarterly or yearly reporting date.'
  end

  def create
    authorize(:module, :reports_write?)
    report = MoneyReconciliationReport.new(kind: params[:kind].presence || 'daily',
      date: params[:date].presence || Time.find_zone!(MoneyReconciliationReport::ZONE).today).save!
    ActivityLogger.log('money_reconciliation_saved', subject: report, details: "#{report.period_kind}: #{report.period_from}..#{report.period_to}")
    redirect_to money_reconciliations_path(saved: report.id), notice: 'Reconciliation review saved. Source records were not changed.'
  rescue ArgumentError
    redirect_to money_reconciliations_path, alert: 'Choose a valid daily, weekly, monthly, quarterly or yearly reporting date.'
  end
end
