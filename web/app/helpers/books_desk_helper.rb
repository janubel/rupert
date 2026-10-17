# frozen_string_literal: true

# Turns BooksDesk steps into links on the pages that own each action, plus
# the small visual vocabulary (state labels and classes) the desk shares.
module BooksDeskHelper
  STAGE_ACTIONS = {
    imported: 'Check source imports', matched: 'Match the registers', followed_up: 'Work the follow-ups',
    reviewed: 'Record the day review', closed: 'Retain the close package', approved: 'Approve the day'
  }.freeze

  STATE_LABELS = {
    done: 'Done', exception: 'Done with exceptions', quiet: 'No sales recorded',
    todo: 'To do', overdue: 'Overdue', info: 'For your information', later: 'Comes with the week', locked: 'Locked', open: 'Open', reopened: 'Reopened'
  }.freeze

  def books_desk_stage_action(stage)
    return financial_close_action_label(stage.blocker) if stage.key == :matched && stage.blocker
    return 'Approve the week' if stage.key == :approved && stage.blocker == :week

    STAGE_ACTIONS.fetch(stage.key)
  end

  def books_desk_stage_path(day, stage)
    date = day.iso8601
    case stage.key
    when :imported then daily_reconciliations_path(day: date, anchor: 'source-evidence')
    when :matched then stage.blocker ? financial_close_blocker_path(stage.blocker, day) : daily_reconciliations_path(day: date, anchor: 'control-comparisons')
    when :followed_up then reconciliation_follow_ups_path(day: date, status: stage.state == :overdue ? 'overdue' : nil)
    when :reviewed then daily_reconciliations_path(day: date, anchor: 'review-history')
    when :closed then financial_close_path(day: date, anchor: 'retain-close')
    when :approved
      if stage.blocker == :week then book_approvals_path(kind: 'weekly', date: day.beginning_of_week.iso8601, anchor: 'approve')
      else book_approvals_path(kind: 'daily', date: date, anchor: 'approve') end
    end
  end

  def books_desk_task_path(task)
    kind, value, extra = task.link
    case kind
    when :week then books_desk_path(week: value.iso8601, anchor: 'desk-focus-week')
    when :locks then period_locks_path(kind: value, date: extra.iso8601, anchor: 'lock-focus')
    when :report then money_reconciliations_path(kind: value, date: extra.iso8601)
    when :settings then settings_path
    when :drive then retention_drive_path
    when :day then (stage = value.next_stage) ? books_desk_stage_path(value.day, stage) : financial_close_path(day: value.day.iso8601)
    when :bank_statements then bank_statements_path
    when :bank_statement then bank_statement_path(value)
    when :expenses then finance_expenses_path(days: 30)
    when :follow_ups then value ? reconciliation_follow_ups_path : reconciliation_follow_ups_path(status: 'overdue')
    when :approve_week then book_approvals_path(kind: 'weekly', date: value.iso8601, anchor: 'approve')
    when :snapshot then business_snapshot_path
    end
  end

  def books_desk_task_action(task)
    return 'Open that week' if task.link&.first == :week
    return 'Open follow-ups' if task.key == :follow_ups && task.link[1]

    { days: 'Open the oldest day', statement: 'Upload a statement', bank_lines: 'Decide bank lines', money_out: 'Open expenses',
      follow_ups: 'Open overdue follow-ups', approve_week: 'Review and approve', snapshot: 'Open snapshot',
      report: 'Open the report', months: 'Lock the next month', quarters: 'Lock the next quarter',
      backup: 'Open settings', drive: 'Drive retention', lock: 'Open the lock page' }.fetch(task.key, 'Open')
  end

  # State of a month, quarter or year for the lock calendar.
  def period_lock_chip_state(event)
    return :todo unless event

    event.lock? ? :done : :later
  end

  def books_desk_state_label(state) = STATE_LABELS.fetch(state, state.to_s.humanize)

  # A tiny glyph that carries meaning with its text label, never by colour alone.
  def books_desk_glyph(state)
    { done: '✓', exception: '!', quiet: '–', todo: '○', overdue: '!', info: 'i', later: '…' }.fetch(state, '○')
  end

  def books_desk_totals(totals)
    return 'No sales recorded' if totals.empty?

    totals.map { |currency, cents| cents.nil? ? "#{currency} unavailable" : "#{currency} #{number_with_precision(cents / 100.0, precision: 2, delimiter: ',')}" }.join(' · ')
  end
end
