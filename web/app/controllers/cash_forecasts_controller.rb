# frozen_string_literal: true

class CashForecastsController < AuthenticatedController
  before_action -> { authorize(:module, :reports_read?) }
  before_action {
    response.headers['Cache-Control'] = 'no-store'
    response.headers['X-Content-Type-Options'] = 'nosniff' }

  def show
    currency = params[:currency].to_s.upcase if params[:currency].to_s.match?(/\A[A-Za-z]{3}\z/)
    @values = { 'as_of' => params[:day].presence || Date.yesterday.iso8601, 'currency' => currency || 'USD', 'horizon' => '8', 'basis' => 'assumption' }
    load_baseline
    @prefill_currencies = CashForecastScenario.retained.map { |doc| doc.metadata['currency'] }.uniq.sort - [@values['currency']]
    return if params[:prefill] == 'none'

    @prefill = CashForecastScenario.prefill(as_of: @baseline.day, currency: @values['currency'])
    @values = @values.merge(@prefill[:values], 'prefilled_from' => @prefill[:document].id.to_s) if @prefill
  rescue ReconciliationEvidence::Error
    redirect_to cash_forecast_path, alert: 'Choose a valid baseline date.'
  end

  def create
    authorize(:module, :reports_write?) if params[:intent] == 'retain'
    @values = params.require(:forecast).permit(:as_of, :currency, :horizon, :opening, :reserve, :basis, :notes, :baseline_digest,
      :zero_confirmation, :prefilled_from, weeks: %i[receipts payments]).to_h
    load_baseline
    @forecast = CashForecastScenario.new(@values)
    if %w[retain csv].include?(params[:intent]) && !@forecast.zeros_confirmed?(@values['zero_confirmation'])
      @confirmation_error = "Confirm the #{@forecast.blank_entries.size} blank weekly #{'entry'.pluralize(@forecast.blank_entries.size)} listed below will be saved as 0, or enter amounts for them."
      return render :show, status: :unprocessable_entity
    end

    if params[:intent] == 'retain'
      raise ReconciliationEvidence::Error, 'The baseline report changed. Recalculate and review before retaining this scenario.' unless @values['baseline_digest'] == @baseline.report.digest

      @retained_document = @forecast.retain!(baseline_digest: @baseline.report.digest, actor: Current.user,
        zero_confirmation: @values['zero_confirmation'], prefilled_from: prefill_source&.id)
      ActivityLogger.log('cash_forecast_retained', subject: @retained_document, details: "baseline #{@forecast.as_of}")
      flash.now[:notice] = "Scenario ##{@retained_document.id} retained with its assumptions. No email or message was sent."
    elsif params[:intent] == 'csv'
      return send_data @forecast.csv, type: 'text/csv', filename: "cash-forecast-#{@forecast.as_of}-#{@forecast.currency}.csv", disposition: 'attachment'
    end
    render :show
  rescue ReconciliationEvidence::Error => e
    @error = e.message
    @error_field = e.field if e.is_a?(CashForecastScenario::FieldError)
    @forecast = nil
    render :show, status: :unprocessable_entity
  end

  private

  def load_baseline
    @baseline = FinancialCloseWorkflow.new(day: @values['as_of'])
  end

  def prefill_source
    ReconciliationDocument.find_by(kind: 'cash_forecast', id: @values['prefilled_from'].to_s[/\A\d+\z/])
  end
end
