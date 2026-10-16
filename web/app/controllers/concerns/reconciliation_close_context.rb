# frozen_string_literal: true

module ReconciliationCloseContext
  private

  def load_close_context(request = @follow_up, from: request&.period_from, to: request&.period_to)
    @close_day = nil
    return if params[:close_day].blank? || from.blank? || to.blank?

    day = ReconciliationEvidence.dates(params[:close_day], params[:close_day]).first
    first, last = ReconciliationEvidence.dates(from.to_s, to.to_s)
    @close_day = day if day.between?(first, last)
  rescue ReconciliationEvidence::Error
    @close_day = nil
  end
end
