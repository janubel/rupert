# frozen_string_literal: true

class CashForecastsController < AuthenticatedController
  before_action -> { authorize(:module, :reports_read?) }
  before_action {
    response.headers['Cache-Control'] = 'no-store'
    response.headers['X-Content-Type-Options'] = 'nosniff' }

  def show
    @values = { 'as_of' => params[:day].presence || Date.yesterday.iso8601, 'currency' => 'USD', 'horizon' => '8', 'basis' => 'assumption' }
    load_baseline
  rescue ReconciliationEvidence::Error
    redirect_to cash_forecast_path, alert: 'Choose a valid baseline date.'
  end

  def create
    authorize(:module, :reports_write?) if params[:intent] == 'retain'
    @values = params.require(:forecast).permit(:as_of, :currency, :horizon, :opening, :reserve, :basis, :notes, :baseline_digest, weeks: %i[receipts payments]).to_h
    load_baseline
    @forecast = CashForecastScenario.new(@values)
    if params[:intent] == 'retain'
      raise ReconciliationEvidence::Error, 'The baseline report changed. Recalculate and review before retaining this scenario.' unless @values['baseline_digest'] == @baseline.report.digest

      doc = @forecast.retain!(baseline_digest: @baseline.report.digest, actor: Current.user)
      @retained_document = doc
      ActivityLogger.log('cash_forecast_retained', subject: doc, details: "baseline #{@forecast.as_of}")
      flash.now[:notice] = "Scenario ##{doc.id} retained with its assumptions. No email or message was sent."
    elsif params[:intent] == 'csv'
      return send_data @forecast.csv, type: 'text/csv', filename: "cash-forecast-#{@forecast.as_of}-#{@forecast.currency}.csv", disposition: 'attachment'
    end
    render :show
  rescue ReconciliationEvidence::Error => e
    @error = e.message
    @forecast = nil
    render :show, status: :unprocessable_entity
  end

  private

  def load_baseline
    @baseline = FinancialCloseWorkflow.new(day: @values['as_of'])
  end
end
