# frozen_string_literal: true

class FinancialCloseController < AuthenticatedController
  before_action -> { authorize(:module, :reports_read?) }
  before_action -> { authorize(:module, :reports_write?) }, only: :create
  before_action {
    response.headers['Cache-Control'] = 'no-store'
    response.headers['X-Content-Type-Options'] = 'nosniff' }

  def show
    @workflow = FinancialCloseWorkflow.new(day: params[:day].presence || Date.yesterday.iso8601)
  rescue ReconciliationEvidence::Error
    redirect_to financial_close_path, alert: 'Choose a valid business date.'
  end

  def create
    @values = params.require(:close).permit(:day, :workflow_digest, :disposition, :notes, *FinancialCloseWorkflow::CHECKS.keys).to_h
    @workflow = FinancialCloseWorkflow.new(day: @values['day'])
    doc = @workflow.retain!(@values, actor: Current.user)
    redirect_to financial_close_path(day: @workflow.day.iso8601, anchor: 'close-history'), notice: "Close package ##{doc.id} retained. Originals and follow-up history remain available. No email or message was sent."
  rescue ReconciliationEvidence::Error => e
    return redirect_to financial_close_path, alert: 'Choose a valid business date.' unless @workflow

    @error = e.message
    render :show, status: :unprocessable_entity
  end
end
