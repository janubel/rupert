# frozen_string_literal: true

# Month, quarter and year locks: the end of the cleanup routine and the
# retention control for historical books. Viewing needs reports.read, locking
# needs reports.write, and unlocking (reopening history) also needs
# settings.write and a written reason. Every lock and unlock is appended to a
# hash-chained ledger and the activity log.
class PeriodLocksController < AuthenticatedController
  before_action -> { authorize(:module, :reports_read?) }
  before_action -> { authorize(:module, :reports_write?) }, only: :create
  before_action do
    response.headers['Cache-Control'] = 'private, no-store'
    response.headers['X-Content-Type-Options'] = 'nosniff'
  end

  def index
    load_page(params[:kind], params[:date])
  rescue PeriodLock::Error => e
    redirect_to period_locks_path, alert: e.message
  end

  def create
    @values = params.require(:period_lock).permit(:kind, :date, :act, :reason, :confirmed).to_h
    load_page(@values['kind'], @values['date'])
    act = @values['act']
    raise PeriodLock::Error, 'Choose lock or unlock.' unless PeriodLock::ACTIONS.include?(act)
    raise PeriodLock::Error, 'Reopening history needs settings access as well. Ask a store administrator.' if act == 'unlock' && !@can_unlock
    raise PeriodLock::Error, 'Tick the box to confirm.' unless @values['confirmed'] == '1'
    raise PeriodLock::Error, 'Explain why this period is being reopened.' if act == 'unlock' && @values['reason'].to_s.strip.empty?
    if act == 'lock' && !@checklist.ready? && @values['reason'].to_s.strip.empty?
      raise PeriodLock::Error, 'Some steps are still open. Add a note saying what is outstanding, or finish them first.'
    end

    event = PeriodLock.record!(action: act, kind: @checklist.kind, date: @checklist.from, reason: @values['reason'], user: Current.user, request: request)
    ActivityLogger.log("period_#{act}ed", subject: event, details: "#{event.label}; fingerprint #{event.fingerprint.first(12)}#{"; reason: #{event.reason.truncate(200)}" if event.reason}")
    notice = act == 'lock' ? "#{event.label} is locked. A dated archive of its totals was retained as evidence ##{event.archive_document_id}." : "#{event.label} is reopened. The reason is recorded in the lock ledger."
    redirect_to period_locks_path(kind: event.period_kind, date: event.period_from.iso8601), notice: notice
  rescue PeriodLock::Error, ReconciliationEvidence::Error, ActiveRecord::RecordInvalid => e
    return redirect_to(period_locks_path, alert: e.message) unless @checklist

    @form_error = e.is_a?(ActiveRecord::RecordInvalid) ? e.record.errors.full_messages.to_sentence : e.message
    render :index, status: :unprocessable_entity
  end

  private

  def load_page(kind, date)
    kind = PeriodLock::KINDS.include?(kind) ? kind : 'monthly'
    @checklist = date.present? ? PeriodCloseChecklist.new(kind: kind, date: date) : PeriodCloseChecklist.latest(kind)
    @events = PeriodLock.latest_events.index_by { |e| [e.period_kind, e.period_from] }
    today = Date.current
    @months = (1..18).map { |n| today.beginning_of_month << n }
    @quarters = (1..8).map { |n| today.beginning_of_quarter << (n * 3) }
    @years = (1..3).map { |n| today.beginning_of_year << (n * 12) }
    @ledger = PeriodLock.chronological.reverse_order.limit(40).to_a
    @chain = PeriodLock.verify_chain
    @can_lock = Current.user.can?('reports.write')
    @can_unlock = @can_lock && Current.user.can?('settings.write')
  end
end
