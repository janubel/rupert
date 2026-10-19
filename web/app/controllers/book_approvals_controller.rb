# frozen_string_literal: true

# The human sign-off screen: look at a day or week of books, then approve it
# into a tamper-evident, dated ledger that records who and when. Viewing needs
# reports.read; approving needs reports.write.
class BookApprovalsController < AuthenticatedController
  before_action -> { authorize(:module, :reports_read?) }
  before_action -> { authorize(:module, :reports_write?) }, only: :create
  before_action do
    response.headers['Cache-Control'] = 'private, no-store'
    response.headers['X-Content-Type-Options'] = 'nosniff'
  end

  def show
    load_page(params[:kind], params[:date])
  rescue BooksPeriod::Error => e
    redirect_to book_approvals_path, alert: e.message
  end

  def create
    values = params.require(:approval).permit(:kind, :date, :digest, :status, :notes, :confirmed)
    load_page(values[:kind], values[:date])
    raise BooksPeriod::Error, 'Only a finished day or week can be approved.' unless @period.complete?
    if (lock = PeriodLock.lock_covering(@period.from, @period.to)) then raise BooksPeriod::Error, PeriodLock.locked_message(lock) end
    raise BooksPeriod::Error, 'The books changed while you were looking. Review the refreshed numbers and approve again.' unless values[:digest] == @period.digest
    raise BooksPeriod::Error, 'Tick the box to confirm you looked at these numbers.' unless values[:confirmed] == '1'
    raise BooksPeriod::Error, 'Choose what you decided.' unless BookApproval::STATUSES.include?(values[:status])
    if values[:status] == 'approved' && @period.issue_total.positive?
      raise BooksPeriod::Error, "#{@period.issue_total} check(s) still need attention. Choose \"Approve with exceptions\" and explain, or mark Needs attention."
    end

    approval = BookApproval.record!(period: @period, status: values[:status], notes: values[:notes], user: Current.user, request: request)
    ActivityLogger.log("books_#{approval.status}", subject: approval,
      details: "#{@period.label}: #{approval.status_label}; fingerprint #{approval.entry_hash.first(12)}")
    redirect_to book_approvals_path(kind: @period.kind, date: @period.from.iso8601),
      notice: "#{approval.status_label} by #{approval.approved_by_name} on #{I18n.l(approval.approved_at.in_time_zone, format: :long)}. Recorded in the approval ledger."
  rescue BooksPeriod::Error, ActiveRecord::RecordInvalid => e
    @form_error = e.is_a?(ActiveRecord::RecordInvalid) ? 'Add a note of 1 to 4000 characters explaining the exception.' : e.message
    @values = values.to_h
    load_page(values[:kind], values[:date]) unless @period
    render :show, status: :unprocessable_entity
  rescue Date::Error
    redirect_to book_approvals_path, alert: 'Choose a valid date to approve.'
  end

  private

  def load_page(kind, date)
    kind = BookApproval::KINDS.include?(kind) ? kind : 'daily'
    @period = date.present? ? BooksPeriod.new(kind: kind, date: date) : BooksPeriod.latest(kind)
    recent = (1..14).map { |n| Date.current - n }
    @strip = BooksPeriod.day_states(recent)
    @history = BookApproval.chronological.reverse_order.limit(30).includes(:approved_by)
    @chain = BookApproval.verify_chain
    @can_write = Current.user.can?('reports.write')
  end
end
