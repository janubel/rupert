# frozen_string_literal: true

module ReconciliationCloseContext
  private

  def load_close_context(request = @follow_up)
    @close_day = nil
    return if params[:close_day].blank? || request&.period_from.blank? || request.period_to.blank?

    day = ReconciliationEvidence.dates(params[:close_day], params[:close_day]).first
    @close_day = day if day.between?(request.period_from, request.period_to)
  rescue ReconciliationEvidence::Error
    @close_day = nil
  end
end
