# frozen_string_literal: true

# Month-end, quarter-end and year-end checklist for one finished period,
# ending in the lock (PeriodLock). Read-only: it reports what is done and
# where to go; locking is a separate, recorded act.
class PeriodCloseChecklist
  Task = Struct.new(:key, :title, :state, :detail, :link, :optional, keyword_init: true) do
    def done? = %i[done info].include?(state)
  end

  attr_reader :kind, :from, :to

  # The most recent finished month, quarter or year.
  def self.latest(kind, today: Date.current)
    date = case kind
           when 'monthly' then today.beginning_of_month - 1
           when 'quarterly' then today.beginning_of_quarter - 1
           else today.beginning_of_year - 1
           end
    new(kind: kind, date: date, today: today)
  end

  def initialize(kind:, date:, today: Date.current)
    @kind = kind
    @today = today
    @from, @to = PeriodLock.bounds(kind, date)
  end

  def label = PeriodLock.label(kind, from)
  def kind_label = PeriodLock::KIND_LABELS.fetch(kind)
  def complete? = to < @today

  def lock_event = @lock_event ||= PeriodLock.latest_for(kind, from)
  def locked? = !!lock_event&.lock?

  # nil when not locked; otherwise whether today's records still match the lock.
  def lock_current?
    return nil unless locked?

    @lock_current = lock_event.still_matches? if @lock_current.nil?
    @lock_current
  end

  def changed_sections
    locked? && !lock_current? ? PeriodSnapshot.new(from: from, to: to).changed_sections(lock_event.summary) : []
  end

  def tasks
    @tasks ||= begin
      base = case kind
             when 'monthly' then month_tasks
             when 'quarterly' then quarter_tasks
             else year_tasks
             end
      base + [lock_task(base.all? { |t| t.done? || t.optional })]
    end
  end

  def open_tasks = tasks.reject { |t| t.done? || t.optional || t.key == :lock }
  def ready? = open_tasks.empty?
  def done_count = tasks.count { |t| t.done? && !t.optional }
  def total_count = tasks.count { |t| !t.optional }

  private

  def month_tasks
    states = BooksPeriod.day_states((from..[to, @today - 1].min).to_a)
    approved = states.count { |_, s| %i[approved approved_with_exceptions].include?(s) }
    first_open = states.reject { |_, s| %i[approved approved_with_exceptions].include?(s) }.keys.min
    days = (to - from).to_i + 1
    [
      Task.new(key: :days, title: 'Every day approved', state: approved == days ? :done : :todo,
        detail: "#{approved} of #{days} days approved#{" · oldest open #{first_open.strftime('%b %-d')}" if first_open}.",
        link: [:week, first_open || from]),
      statement_task, bank_lines_task, follow_ups_task, report_task
    ]
  end

  def quarter_tasks
    months = (0..2).map { |n| from >> n }
    locked = months.count { |m| PeriodLock.latest_for('monthly', m)&.lock? }
    [
      Task.new(key: :months, title: 'All three months locked', state: locked == 3 ? :done : :todo,
        detail: "#{locked} of 3 months locked.", link: [:locks, 'monthly', months.find { |m| !PeriodLock.latest_for('monthly', m)&.lock? } || from]),
      follow_ups_task, report_task
    ]
  end

  def year_tasks
    quarters = (0..3).map { |n| from >> (n * 3) }
    locked = quarters.count { |q| PeriodLock.latest_for('quarterly', q)&.lock? }
    backup = BackupLog.unscoped.where(tenant_id: nil, status: 'success').where('"startedAt" >= ?', 7.days.ago).exists?
    drive = RetentionDriveConnection.first&.connected?
    [
      Task.new(key: :quarters, title: 'All four quarters locked', state: locked == 4 ? :done : :todo,
        detail: "#{locked} of 4 quarters locked.", link: [:locks, 'quarterly', quarters.find { |q| !PeriodLock.latest_for('quarterly', q)&.lock? } || from]),
      follow_ups_task, report_task,
      Task.new(key: :backup, title: 'An off-host backup succeeded this week', state: backup ? :done : :todo,
        detail: backup ? 'The database has a recent copy away from this machine.' : 'No successful off-host backup in the last 7 days. Keep one before relying on a year lock.',
        link: [:settings]),
      Task.new(key: :drive, title: 'Originals copied to Google Drive', state: drive ? :done : :info, optional: !drive,
        detail: drive ? 'Drive retention is connected; check its copy status.' : 'Optional. Originals stay encrypted in Rupert either way.',
        link: [:drive])
    ]
  end

  def statement_task
    covered = ReconciliationDocument.where(kind: 'bank_statement').where('period_to >= ?', to - 3).where('period_from <= ?', to).exists?
    Task.new(key: :statement, title: 'Bank statements reach the end of the period', state: covered ? :done : :todo,
      detail: covered ? "A statement covers #{to.strftime('%b %-d')}." : "No statement reaches #{(to - 3).strftime('%b %-d')} yet.", link: [:bank_statements])
  end

  def bank_lines_task
    waiting = BankStatementLine.pending.where(posted_on: from..to)
    count = waiting.count
    Task.new(key: :bank_lines, title: 'Every bank line decided', state: count.zero? ? :done : :todo,
      detail: count.zero? ? 'No bank lines waiting in this period.' : "#{count} line#{'s' unless count == 1} still waiting.",
      link: (doc = waiting.order(:document_id).pick(:document_id)) ? [:bank_statement, doc] : [:bank_statements])
  end

  def follow_ups_task
    open = ReconciliationFollowUp.active.where('period_from <= ? AND period_to >= ?', to, from).count
    Task.new(key: :follow_ups, title: 'No open follow-ups for the period', state: open.zero? ? :done : :todo,
      detail: open.zero? ? 'Nothing open.' : "#{open} still open or waiting.", link: [:follow_ups, from])
  end

  def report_task
    saved = MoneyReconciliation.where(period_kind: kind, period_from: from).exists?
    Task.new(key: :report, title: "#{kind_label} money report saved", state: saved ? :done : :todo,
      detail: saved ? 'A dated source review is retained.' : 'Save the source review so the period’s totals are retained as evidence.',
      link: [:report, kind, from])
  end

  def lock_task(ready)
    state, detail = lock_state(ready)
    Task.new(key: :lock, title: "Lock the #{kind_label.downcase}", state: state, detail: detail, link: [:locks, kind, from])
  end

  def lock_state(ready)
    if locked? && lock_current?
      return [:done, "Locked by #{lock_event.actor_name} on #{lock_event.acted_at.in_time_zone.strftime('%b %-d, %Y')}."]
    end
    return [:overdue, "Locked, but records changed afterwards: #{changed_sections.join(', ').presence || 'details on the locks page'}."] if locked?
    return [:todo, 'This period has not finished yet.'] unless complete?
    return [:todo, 'Everything above is done. Lock it so history cannot be edited by accident.'] if ready

    [:todo, 'You can lock now with a note about what is still open, or finish the steps above first.']
  end
end
