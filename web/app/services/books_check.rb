# frozen_string_literal: true

require 'csv'

# Read-only integrity audit of the canonical money records. Each check answers
# one plain question ("do paid orders have payments?") and reports ok / watch /
# fix with the exact count, the dollars involved and where to go next. Nothing
# here writes data or changes a source; unknown stays unknown, never zero.
class BooksCheck
  Check = Struct.new(:key, :title, :status, :count, :cents, :detail, :action, :path, :rows, keyword_init: true) do
    def ok? = status == :ok
  end

  ORDER_STATUSES = %w[paid fulfilled].freeze
  SAMPLE = 10
  STALE_SOURCE_DAYS = 3

  attr_reader :window_days, :since, :generated_at

  def initialize(window_days: 30)
    @window_days = window_days.to_i.clamp(7, 365)
    @generated_at = Time.current
    @since = @generated_at - @window_days.days
  end

  def checks
    @checks ||= [source_freshness, sync_health, paid_without_payment, payment_mismatch, refund_records,
      orders_without_location, impossible_amounts, missing_controls, unreviewed_days,
      overdue_follow_ups, evidence_integrity, approval_ledger, locked_periods, unapproved_days, offsite_backup, bank_lines_waiting].compact
  end

  def summary
    counts = checks.group_by(&:status).transform_values(&:size)
    { fix: counts.fetch(:fix, 0), watch: counts.fetch(:watch, 0), ok: counts.fetch(:ok, 0), total: checks.size }
  end

  def verdict
    s = summary
    return :fix if s[:fix].positive?

    s[:watch].positive? ? :watch : :ok
  end

  def csv
    CSV.generate do |csv|
      csv << ['Books check', generated_at.iso8601, "Last #{window_days} days", 'Read-only; amounts in integer cents']
      csv << %w[Check Status Count Cents Detail Next\ step]
      checks.each { |c| csv << [c.title, c.status, c.count, c.cents, c.detail, c.action] }
      checks.reject(&:ok?).each do |c|
        next if c.rows.blank?

        csv << []
        csv << [c.title, 'Examples (up to 10)']
        c.rows.each { |row| csv << Array(row).map { |v| safe(v) } }
      end
    end
  end

  private

  def routes
    Rails.application.routes.url_helpers
  end

  def orders
    Core::Order.where('occurred_at >= ?', since)
  end

  def sales
    orders.where(status: ORDER_STATUSES)
  end

  def build(key, title, count:, cents: nil, detail_ok:, detail_bad:, action: nil, path: nil, rows: [], level: :fix)
    bad = count.to_i.positive?
    Check.new(key: key, title: title, status: bad ? level : :ok, count: count.to_i, cents: cents,
      detail: bad ? detail_bad : detail_ok, action: bad ? action : nil, path: bad ? path : nil, rows: bad ? rows : [])
  end

  # Quiet is not broken, but a source with no new orders for days while others
  # are active is exactly how a dead token or schedule hides.
  def source_freshness
    latest = Core::Order.group(:source).maximum(:occurred_at)
    stale = latest.select { |_, at| at < generated_at - STALE_SOURCE_DAYS.days }
    rows = latest.map { |source, at| [source, at.in_time_zone.iso8601, ((generated_at - at) / 1.day).floor] }
    build('source_freshness', 'Every sales source is still reporting',
      count: stale.size, level: :watch, rows: rows,
      detail_ok: "All #{latest.size} sources have an order in the last #{STALE_SOURCE_DAYS} days.",
      detail_bad: "No new orders for #{STALE_SOURCE_DAYS}+ days from: #{stale.keys.map(&:to_s).sort.join(', ')}. Confirm the source is genuinely quiet and its connection is healthy.",
      action: 'Open Source sync status and confirm the connection and last success.', path: routes.syncs_path)
  end

  def sync_health
    runs = SyncRun.where('"startedAt" >= ?', generated_at - 2.days).order(startedAt: :desc).limit(40).to_a
    latest_failed = runs.first&.status == 'failed'
    failed = runs.count { |run| run.status == 'failed' }
    build('sync_health', 'Scheduled imports are succeeding',
      count: latest_failed ? failed : 0, level: latest_failed ? :fix : :watch,
      rows: runs.select { |r| r.status == 'failed' }.first(SAMPLE).map { |r| [r.startedAt&.iso8601, r.source, r.mode, r.error.to_s.truncate(120)] },
      detail_ok: failed.zero? ? 'No failed imports in the last 2 days.' : "#{failed} earlier failure(s) in the last 2 days, latest import succeeded.",
      detail_bad: "The most recent import failed (#{failed} failures in 2 days). Sales may be missing.",
      action: 'Check the failure message, then re-run the import from Source sync status.', path: routes.syncs_path)
  end

  # A paid order with a real total but no recorded payment cannot be tied to
  # tenders, so it falls out of the register and cash-vs-card totals.
  def paid_without_payment
    scope = sales.where('gross_cents > 0').where.not(id: Core::Payment.select(:order_id).where(status: 'completed'))
    build('paid_without_payment', 'Every paid order has a payment', count: scope.count, cents: scope.sum(:gross_cents),
      rows: scope.order(occurred_at: :desc).limit(SAMPLE).pluck(:source, :order_number, :occurred_at, :gross_cents),
      detail_ok: 'Every paid order with a total has a completed payment.',
      detail_bad: 'These paid orders carry a total but no completed payment, so they are missing from tender totals.',
      action: 'Re-import the day from the source; if it persists, add the payment from the original receipt.')
  end

  def payment_mismatch
    paid = Core::Payment.where(status: 'completed').group(:order_id).sum(:amount_cents)
    mismatched = sales.where(id: paid.keys).pluck(:id, :source, :order_number, :occurred_at, :gross_cents).filter_map do |id, source, number, at, gross|
      diff = paid[id].to_i - gross.to_i
      [source, number, at, gross, paid[id], diff] unless diff.zero?
    end
    build('payment_mismatch', 'Payments equal order totals', count: mismatched.size,
      cents: mismatched.sum { |row| row.last.abs },
      rows: mismatched.sort_by { |row| -row.last.abs }.first(SAMPLE),
      detail_ok: 'Completed payments equal the order total on every paid order.',
      detail_bad: 'Order total and completed payments disagree (tips, split tenders or partial capture are common causes).',
      action: 'Open the order and compare to the processor receipt; document the difference on the day review.')
  end

  # Orders marked refunded without a refund record leave Refunds at $0 on the
  # Financial report while the sale silently drops out of revenue.
  def refund_records
    refunded = Core::Order.where(status: 'refunded').where('occurred_at >= ?', since)
    scope = refunded.where.not(id: Core::Refund.select(:order_id))
    build('refund_records', 'Refunded orders have refund records', count: scope.count,
      cents: scope.sum(:gross_cents),
      rows: scope.order(occurred_at: :desc).limit(SAMPLE).pluck(:source, :order_number, :occurred_at, :gross_cents),
      detail_ok: 'Every refunded order has a refund record (or none refunded).',
      detail_bad: 'These orders are marked refunded but have no refund amount, so Financial-report refunds are understated.',
      action: 'Record the refund amount from the source, or confirm the order total was $0.')
  end

  def orders_without_location
    scope = sales.where(location_id: [nil, ''])
    by_source = scope.group(:source).count
    build('orders_without_location', 'Orders are assigned to a location', count: scope.count, level: :watch,
      cents: scope.sum(:gross_cents), rows: by_source.map { |source, n| [source, n] },
      detail_ok: 'Every paid order has a location.',
      detail_bad: 'Sales without a location are shown as "Unassigned" in location reports and cannot be matched to a register control.',
      action: 'Map the source channel to a Location in Settings.', path: routes.locations_path)
  end

  def impossible_amounts
    scope = orders.where('gross_cents < 0 OR tax_cents < 0 OR tax_cents > gross_cents OR tip_cents < 0')
    build('impossible_amounts', 'No impossible amounts', count: scope.count, cents: scope.sum(:gross_cents),
      rows: scope.limit(SAMPLE).pluck(:source, :order_number, :gross_cents, :tax_cents),
      detail_ok: 'No negative amounts and no tax larger than its order.',
      detail_bad: 'These orders have a negative amount or tax above the order total.',
      action: 'Inspect the original in the source system.')
  end

  def sales_days
    @sales_days ||= begin
      zone = Time.zone
      from = [(generated_at.in_time_zone - 7.days).to_date, since.to_date].max
      sales.where('occurred_at >= ?', zone.local(from.year, from.month, from.day))
        .pluck(:occurred_at).map { |t| t.in_time_zone.to_date }.uniq.reject { |d| d >= Date.current }.sort
    end
  end

  def missing_controls
    covered = ReconciliationDocument.where(kind: 'register_control').where('period_to >= ?', sales_days.first || Date.current)
      .pluck(:period_from, :period_to)
    missing = sales_days.reject { |day| covered.any? { |from, to| from <= day && to >= day } }
    build('missing_controls', 'Recent days have a register report to compare against', count: missing.size,
      level: :watch, rows: missing.map { |d| [d.iso8601] },
      detail_ok: 'Every recent sales day has a retained register control.',
      detail_bad: "No register control retained for: #{missing.map(&:iso8601).first(7).join(', ')}. Without one, that day cannot be compared to the source's own total.",
      action: 'Open Daily checks for the day and upload or enter the source register report.',
      path: missing.first && routes.daily_reconciliations_path(day: missing.first.iso8601))
  end

  def unreviewed_days
    reviewed = DailyReconciliationReview.where(day: sales_days).where(status: 'reviewed').pluck(:day).to_set
    missing = sales_days.reject { |d| reviewed.include?(d) }
    build('unreviewed_days', 'Recent days have been reviewed', count: missing.size, level: :watch,
      rows: missing.map { |d| [d.iso8601] },
      detail_ok: 'Every recent sales day has a Reviewed sign-off.',
      detail_bad: "Not yet reviewed: #{missing.map(&:iso8601).first(7).join(', ')}.",
      action: 'Open Financial close for the day and record a review.',
      path: missing.first && routes.financial_close_path(day: missing.first.iso8601))
  end

  def overdue_follow_ups
    scope = ReconciliationFollowUp.active.where('due_on < ?', Date.current)
    build('overdue_follow_ups', 'No overdue reconciliation follow-ups', count: scope.count, level: :watch,
      rows: scope.order(:due_on).limit(SAMPLE).pluck(:due_on, :title),
      detail_ok: 'No follow-up is past its due date.',
      detail_bad: 'Follow-ups are past due.', action: 'Open Follow-ups and record the next step.',
      path: routes.reconciliation_follow_ups_path)
  end

  # Re-verifies the stored checksum of recently retained originals. A failure
  # means retained evidence no longer matches what was uploaded.
  def evidence_integrity
    docs = ReconciliationDocument.where('created_at >= ?', since).order(id: :desc).limit(200)
    failed = docs.filter_map do |doc|
      doc.original_bytes
      nil
    rescue StandardError => e
      [doc.id, doc.filename, e.class.name]
    end
    build('evidence_integrity', "Retained originals still match their checksums", count: failed.size,
      rows: failed.first(SAMPLE),
      detail_ok: "#{docs.size} recently retained original(s) re-verified against their SHA-256.",
      detail_bad: 'These retained documents failed checksum verification. Do not rely on them.',
      action: 'Restore from backup and re-retain the original; keep the failed record for the audit trail.')
  end

  # The approval ledger is hash-chained; any edited, removed or reordered
  # entry shows here.
  def approval_ledger
    result = BookApproval.verify_chain
    build('approval_ledger', 'The approval ledger is intact', count: result[:ok] ? 0 : 1,
      rows: [[result[:broken_id], result[:reason]]],
      detail_ok: "#{result[:count]} approval(s), each linked to the one before it.",
      detail_bad: "Ledger check failed at entry #{result[:broken_id] || '?'}: #{result[:reason]} Treat approvals after that point as unverified.",
      action: 'Restore the database from the last good backup and compare, then re-approve the affected periods.',
      path: routes.book_approvals_path)
  end

  # Locked months, quarters and years: the lock ledger is intact and each
  # period's records still match the fingerprint taken when it was locked.
  def locked_periods
    chain = PeriodLock.verify_chain
    locks = PeriodLock.active_locks.last(40)
    drifted = locks.reject(&:still_matches?)
    problems = (chain[:ok] ? 0 : 1) + drifted.size
    rows = drifted.map { |lock| [lock.label, lock.actor_name, lock.acted_at.to_date.iso8601] }
    rows.unshift(['Lock ledger', chain[:broken_id], chain[:reason]]) unless chain[:ok]
    build('locked_periods', 'Locked periods still match what was locked', count: problems, level: chain[:ok] ? :watch : :fix, rows: rows,
      detail_ok: locks.empty? ? 'No period is locked yet. Lock finished months from the Books desk.' : "#{locks.size} locked period(s) unchanged; lock ledger intact.",
      detail_bad: chain[:ok] ? "Records changed after locking: #{drifted.map(&:label).join(', ')}. Usually a late source import." : "Lock ledger check failed: #{chain[:reason]}",
      action: 'Open Locked periods, inspect what changed, then reopen with a reason and lock again if the new numbers are right.',
      path: routes.period_locks_path(kind: drifted.first&.period_kind, date: drifted.first&.period_from&.iso8601))
  end

  def unapproved_days
    states = BooksPeriod.day_states((1..7).map { |n| Date.current - n }.reverse)
    open = states.select { |day, state| state == :pending && sales_days.include?(day) }.keys
    build('unapproved_days', 'Recent days have been approved by a person', count: open.size, level: :watch,
      rows: open.map { |d| [d.iso8601] },
      detail_ok: 'Every recent sales day has a recorded human approval.',
      detail_bad: "Waiting for approval: #{open.map(&:iso8601).first(7).join(', ')}.",
      action: 'Open Approve books and sign off the day or week.',
      path: open.first && routes.book_approvals_path(kind: 'daily', date: open.first.iso8601))
  end

  # A local database backup exists on the host, but a copy that survives losing
  # the machine only counts once an off-host upload has succeeded.
  def offsite_backup
    recent = BackupLog.unscoped.where(tenant_id: nil, status: 'success').where('"startedAt" >= ?', generated_at - 7.days).exists?
    build('offsite_backup', 'An off-host backup succeeded in the last 7 days', count: recent ? 0 : 1, level: :watch,
      detail_ok: 'A Google Drive backup upload succeeded this week.',
      detail_bad: 'No successful off-host backup is recorded. The books exist only on this machine and its local snapshots.',
      action: 'Connect Google Drive backup in Settings (platform administrator).', path: routes.settings_path)
  end

  def bank_lines_waiting
    scope = BankStatementLine.pending
    build('bank_lines_waiting', 'Uploaded bank lines have a decision', count: scope.count, level: :watch,
      cents: scope.where('amount_cents < 0').sum('-amount_cents'),
      rows: scope.group(:document_id, :account_label).count.map { |(doc, label), n| [label, doc, n] }.first(SAMPLE),
      detail_ok: 'Every uploaded bank line is recorded or ignored (or none uploaded).',
      detail_bad: 'Bank statement lines are waiting for someone to say what they were. Withdrawals left undecided are missing from money out.',
      action: 'Open Bank statements and decide the waiting lines.', path: routes.bank_statements_path)
  end

  def safe(value)
    text = value.to_s
    text.match?(/\A\s*[=+\-@]/) ? "'#{text}" : text
  end
end
