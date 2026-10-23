# frozen_string_literal: true

# The Books desk: one place for the daily and weekly cleanup routine.
#
# For each finished business day it reads the checks Rupert already keeps
# (source imports, register controls, follow-ups, the day review, the close
# package and the human approval) and lines them up as six ordered steps with
# the single next thing to do. For a finished week it adds the weekly chores:
# the bank statement, its undecided lines, money out, overdue follow-ups and
# the weekly approval.
#
# Read-only. Every action still happens on the page that owns it; this class
# only decides what is done, what is not, and which page to open next. Each
# day's FinancialCloseWorkflow is built once and shared with BooksPeriod.
class BooksDesk
  Error = Class.new(ArgumentError)

  STAGES = {
    imported: ['Sales in', 'Every sales source finished importing this date.'],
    matched: ['Registers match', 'Each source has its own register report and the totals agree.'],
    followed_up: ['Follow-ups', 'No open questions or requested reports for this date.'],
    reviewed: ['Reviewed', 'A person reviewed the current numbers.'],
    closed: ['Closed', 'A close package is retained for the current numbers.'],
    approved: ['Approved', 'Signed off on its own or as part of its week.']
  }.freeze

  # Register-control problems, in the order the close page works them.
  MATCH_KEYS = %i[missing_controls conflicts variances unavailable coverage].freeze
  DONE_STATES = %i[done exception quiet].freeze

  Stage = Struct.new(:key, :label, :hint, :state, :count, :detail, :blocker, keyword_init: true) do
    def done? = DONE_STATES.include?(state)
  end

  # :later marks a step that is not due yet (a day in the unfinished week
  # waits for the weekly sign-off). It is not done, but it is never "next".
  ACTIONABLE_STATES = %i[todo overdue].freeze

  Day = Struct.new(:day, :orders, :totals, :stages, keyword_init: true) do
    def complete? = stages.all?(&:done?)
    def next_stage = stages.find { |stage| ACTIONABLE_STATES.include?(stage.state) && !(stage.key == :approved && stage.blocker == :week) }
    def daily_cleanup_complete? = stages.reject { |stage| stage.key == :approved }.all?(&:done?)
    def actionable? = !next_stage.nil?
    def done_count = stages.count(&:done?)
    def quiet? = orders.zero?
  end

  Task = Struct.new(:key, :title, :state, :detail, :link, :optional, keyword_init: true) do
    def done? = %i[done info].include?(state)
  end

  attr_reader :today, :current_week, :focus_week

  def initialize(today: Date.current, week: nil)
    @today = today
    @current_week = today.beginning_of_week
    last_complete = @current_week - 7
    @focus_week = week.present? ? [parse(week).beginning_of_week, last_complete].min : last_complete
    @rows = {}
    @workflows = {}
    @weekly = {}
  end

  # Finished days of the current week, newest first. Empty on a Monday.
  def this_week_days = (current_week...today).to_a.reverse.map { |day| row(day) }

  # The finished week under review, newest first.
  def focus_days = week_dates(focus_week).reverse.map { |day| row(day) }

  def focus_label = week_label(focus_week)
  def previous_week = focus_week - 7
  def next_week = focus_week + 7 < current_week ? focus_week + 7 : nil

  # Oldest unfinished day first, so a backlog is worked in order and nothing
  # is skipped because a newer day looked more urgent.
  def next_day
    (focus_days + this_week_days).select(&:actionable?).min_by(&:day)
  end

  def next_task
    focus_tasks.find { |task| !task.done? && !task.optional }
  end

  # [checklist, task] for the first open month / quarter / year-end step.
  def next_period_step
    period_closes.each do |close|
      task = close.tasks.find { |t| !t.done? && !t.optional }
      return [close, task] if task
    end
    nil
  end

  def all_clear? = next_day.nil? && next_task.nil? && next_period_step.nil?

  def progress
    days = focus_days + this_week_days
    { days: days.size, up_to_date: days.count { |d| !d.actionable? }, steps: days.sum { |d| d.stages.size }, steps_done: days.sum(&:done_count) }
  end

  def focus_tasks
    @focus_tasks ||= week_tasks(focus_week)
  end

  def week_period(monday)
    @weekly[monday] ||= with_approvals(BooksPeriod.new(kind: 'weekly', date: monday, workflows: workflows_for(week_dates(monday))))
  end

  # Approvals for the desk's recent window, read once; older periods query their own.
  APPROVAL_WINDOW = 120

  def with_approvals(period)
    return period if period.from < today - APPROVAL_WINDOW

    @recent_approvals ||= BookApproval.where(period_from: (today - APPROVAL_WINDOW)..today).chronological.to_a
    period.preload_approvals!(@recent_approvals)
  end

  # Month, quarter and year end for the most recent finished period of each.
  def period_closes
    @period_closes ||= PeriodLock::KINDS.map { |kind| PeriodCloseChecklist.latest(kind, today: today) }
  end

  def overdue_follow_ups
    @overdue_follow_ups ||= ReconciliationFollowUp.active.where('due_on < ?', today).count
  end

  def pending_bank_lines
    @pending_bank_lines ||= BankStatementLine.pending.count
  end

  private

  def parse(value)
    date = value.is_a?(Date) ? value : Date.iso8601(value.to_s)
    raise Error, 'Choose a date between 2000 and 2099.' unless date.year.between?(2000, 2099)

    date
  rescue Date::Error
    raise Error, 'Use a date in YYYY-MM-DD format.'
  end

  def week_dates(monday) = (monday..monday + 6).to_a

  def week_label(monday)
    sunday = monday + 6
    "#{monday.strftime('%b %-d')} – #{sunday.strftime(monday.month == sunday.month ? '%-d, %Y' : '%b %-d, %Y')}"
  end

  def workflow(day)
    @workflows[day] ||= FinancialCloseWorkflow.new(day: day.iso8601)
  end

  def workflows_for(days) = days.index_with { |day| workflow(day) }

  def row(day)
    @rows[day] ||= begin
      wf = workflow(day)
      register = wf.report.register.rows
      totals = register.group_by { |r| r[:currency].presence || 'Unknown' }
        .transform_values { |rows| rows.any? { |r| r[:order_total_cents].nil? } ? nil : rows.sum { |r| r[:order_total_cents] } }
      Day.new(day: day, orders: register.sum { |r| r[:orders].to_i }, totals: totals, stages: stages_for(day, wf))
    end
  end

  def stages_for(day, wf)
    [
      stage(:imported, import_state(wf)),
      stage(:matched, match_state(wf)),
      stage(:followed_up, follow_up_state(wf)),
      stage(:reviewed, review_state(wf)),
      stage(:closed, close_state(wf)),
      stage(:approved, approval_stage(day))
    ]
  end

  def quiet?(wf) = wf.report.register.rows.sum { |r| r[:orders].to_i }.zero?

  def import_state(wf)
    unconfirmed = wf.issues[:unconfirmed_imports].to_i
    return [:todo, unconfirmed, "#{pluralize(unconfirmed, 'source')} not confirmed", :unconfirmed_imports] if unconfirmed.positive?
    return [:quiet, 0, 'No sales recorded. Confirm the day was genuinely quiet.', nil] if quiet?(wf)

    [:done, 0, 'All sources confirmed', nil]
  end

  def match_state(wf)
    issues = wf.issues
    count = MATCH_KEYS.sum { |key| issues[key].to_i }
    return [:todo, count, match_detail(issues), MATCH_KEYS.find { |key| issues[key].to_i.positive? }] if count.positive?

    [:done, 0, quiet?(wf) ? 'Nothing to compare' : 'Every register agrees', nil]
  end

  def follow_up_state(wf)
    open = wf.open_follow_ups
    overdue = open.count(&:overdue?)
    return [:overdue, open.size, "#{overdue} overdue", :open_follow_ups] if overdue.positive?
    return [:todo, open.size, "#{open.size} open", :open_follow_ups] if open.any?

    [:done, 0, 'None open', nil]
  end

  def close_state(wf)
    package = wf.packages.first
    return [:todo, nil, 'No close package yet', nil] if package.nil?
    return [:todo, nil, 'Numbers changed since the close', nil] if package.metadata['workflow_digest'] != wf.digest
    return [:exception, nil, 'Closed with exceptions', nil] if package.metadata['disposition'] == 'with_exceptions'

    [:done, nil, 'Closed', nil]
  end

  def stage(key, (state, count, detail, blocker))
    label, hint = STAGES.fetch(key)
    Stage.new(key: key, label: label, hint: hint, state: state, count: count, detail: detail, blocker: blocker)
  end

  def match_detail(issues)
    { missing_controls: 'missing', conflicts: 'conflicting', variances: 'differ', unavailable: 'unavailable', coverage: 'coverage flags' }
      .filter_map { |key, word| "#{issues[key]} #{word}" if issues[key].to_i.positive? }.join(' · ')
  end

  def review_state(wf)
    review = wf.review
    return [:todo, nil, 'Not reviewed yet', :review] unless review
    return [:todo, nil, 'Numbers changed since the review', :review] unless wf.review_current?
    return [:todo, nil, 'Marked needs attention', :review] unless review.status == 'reviewed'

    [:done, nil, "Reviewed by #{review.reviewed_by&.display_name.presence || review.reviewed_by&.email || 'a person'}", nil]
  end

  # The newest approval that covers the day wins, whether it was for the day
  # alone or its whole week. A changed approval needs a fresh look. Days of a
  # finished week point at the weekly sign-off (blocker :week); days of the
  # current week wait for it instead of nagging for a daily approval.
  def approval_stage(day)
    periods = [with_approvals(BooksPeriod.new(kind: 'daily', date: day, workflows: workflows_for([day])))]
    monday = day.beginning_of_week
    week_done = monday + 6 < today
    periods << week_period(monday) if week_done
    latest = periods.filter_map { |p| (a = p.latest_approval) && [a, p] }.max_by { |a, _| [a.approved_at, a.id] }
    unless latest
      return week_done ? [:todo, nil, 'Waiting for the week’s sign-off', :week] : [:later, nil, 'Signs off with its week', nil]
    end

    approval, period = latest
    scope = period.kind == 'weekly' ? 'with its week' : 'on its own'
    blocker = period.kind == 'weekly' ? :week : nil
    case period.state
    when :changed then [:todo, nil, 'Numbers changed since approval', blocker]
    when :needs_attention then [:todo, nil, "Marked needs attention #{scope}", blocker]
    when :approved_with_exceptions then [:exception, nil, "Approved with exceptions #{scope}", nil]
    else [:done, nil, "#{approval.approved_by_name} approved #{scope}", nil]
    end
  end

  def week_tasks(monday)
    sunday = monday + 6
    days = focus_days
    open_days = days.reject(&:daily_cleanup_complete?)
    lines = BankStatementLine.where(posted_on: monday..sunday)
    waiting = lines.pending
    statement = ReconciliationDocument.where(kind: 'bank_statement').where('period_to >= ?', sunday - 2).where('period_from <= ?', sunday).exists?
    expenses = Finance::Expense.where(incurred_on: monday..sunday)
    payments = Finance::VendorPayment.where(paid_on: monday..sunday)
    period = week_period(monday)
    snapshot = ReconciliationDocument.where(kind: 'period_archive', source: 'rupert').where('filename LIKE ?', 'business-snapshot-%')
      .where(created_at: monday.beginning_of_day..(sunday + 7).end_of_day).exists?

    [
      Task.new(key: :days, title: 'Finish daily reviews and closes',
        state: open_days.empty? ? :done : :todo,
        detail: open_days.empty? ? 'Every day is reviewed and closed. Approve the week after the remaining chores.' : "#{7 - open_days.size} of 7 days reviewed and closed. Oldest open: #{open_days.min_by(&:day).day.strftime('%a %b %-d')}.",
        link: open_days.min_by(&:day)&.then { |d| [:day, d] }),
      Task.new(key: :statement, title: 'Upload the bank statement for the week',
        state: statement ? :done : :todo,
        detail: statement ? 'A statement covers the end of this week.' : "No statement reaches #{(sunday - 2).strftime('%a %b %-d')} yet. Download the CSV from the bank and upload it.",
        link: [:bank_statements]),
      Task.new(key: :bank_lines, title: 'Say what every bank line was',
        state: waiting.exists? ? :todo : :done,
        detail: bank_lines_detail(waiting, lines),
        link: waiting.order(:document_id).pick(:document_id)&.then { |id| [:bank_statement, id] } || [:bank_statements]),
      Task.new(key: :money_out, title: 'Check money out',
        state: :info,
        detail: "#{pluralize(expenses.count, 'expense')} (#{money(expenses.sum(:amount_cents))}) · #{pluralize(payments.count, 'vendor payment')} (#{money(payments.sum(:amount_cents))}). Add anything paid outside the bank feed.",
        link: [:expenses]),
      Task.new(key: :follow_ups, title: 'Clear overdue follow-ups',
        state: overdue_follow_ups.zero? ? :done : :todo,
        detail: overdue_follow_ups.zero? ? 'Nothing is past due.' : "#{pluralize(overdue_follow_ups, 'follow-up')} past due, across all dates.",
        link: [:follow_ups]),
      Task.new(key: :approve_week, title: 'Approve the week',
        state: { approved: :done, approved_with_exceptions: :done }.fetch(period.state, :todo),
        detail: week_approval_detail(period),
        link: [:approve_week, monday]),
      Task.new(key: :snapshot, title: 'Save a dated business snapshot', optional: true,
        state: snapshot ? :done : :todo,
        detail: snapshot ? 'A snapshot was saved for this week.' : 'Optional. Keeps a printable record of sales, cash and vendors as they stood.',
        link: [:snapshot])
    ]
  end

  def bank_lines_detail(waiting, lines)
    return "#{pluralize(waiting.count, 'line')} from this week still waiting for a decision." if waiting.exists?
    return "All #{pluralize(lines.count, 'line')} from this week are recorded or ignored." if lines.exists?

    'No bank lines uploaded for this week.'
  end

  def week_approval_detail(period)
    approval = period.latest_approval
    case period.state
    when :pending then period.issue_total.positive? ? "Not approved. #{pluralize(period.issue_total, 'check')} still open; you can approve with exceptions." : 'Not approved yet. Nothing flagged.'
    when :changed then "#{approval.approved_by_name} approved it, but the numbers changed afterwards. Look again."
    when :needs_attention then "#{approval.approved_by_name} marked it needs attention."
    else "#{approval.status_label} by #{approval.approved_by_name}."
    end
  end

  def pluralize(count, word) = ActionController::Base.helpers.pluralize(count, word)
  def money(cents) = ActionController::Base.helpers.number_to_currency(cents.to_i / 100.0)
end
