# frozen_string_literal: true

require 'digest'

# One day or one Monday-to-Sunday week of books, prepared for a human to look at
# and approve. Gathers what the existing reports already compute (register,
# controls, coverage, follow-ups) plus money out, produces a stable fingerprint
# of the evidence, and says whether a prior approval still matches it. It reads
# only; approving is a separate, recorded act (BookApproval.record!).
class BooksPeriod
  Error = Class.new(ArgumentError)
  ZONE_TODAY = -> { Date.current }

  attr_reader :kind, :from, :to

  # The most recent complete period: yesterday, or last Monday-Sunday week.
  def self.latest(kind)
    today = ZONE_TODAY.call
    kind == 'weekly' ? new(kind: 'weekly', date: today.beginning_of_week - 7) : new(kind: 'daily', date: today - 1)
  end

  # workflows: optional { Date => FinancialCloseWorkflow } already built by the
  # caller (the Books desk), so a page showing many periods builds each day once.
  def initialize(kind:, date:, workflows: nil)
    raise Error, 'Choose a daily or weekly approval.' unless BookApproval::KINDS.include?(kind)

    day = date.is_a?(Date) ? date : Date.iso8601(date.to_s)
    raise Error, 'Choose a date between 2000 and 2099.' unless day.year.between?(2000, 2099)

    @kind = kind
    @from, @to = kind == 'weekly' ? [day.beginning_of_week, day.end_of_week] : [day, day]
    @workflows = workflows.slice(*days) if workflows && days.all? { |d| workflows.key?(d) }
  rescue Date::Error
    raise Error, 'Use a date in YYYY-MM-DD format.'
  end

  def complete? = to < ZONE_TODAY.call
  def days = (from..to).to_a
  def previous = self.class.new(kind: kind, date: kind == 'weekly' ? from - 7 : from - 1)
  def next_period = self.class.new(kind: kind, date: kind == 'weekly' ? from + 7 : from + 1)
  def label = kind == 'weekly' ? "Week of #{from.strftime('%b %-d')} to #{to.strftime('%b %-d, %Y')}" : from.strftime('%A, %b %-d, %Y')

  def workflows
    @workflows ||= days.to_h { |day| [day, FinancialCloseWorkflow.new(day: day.iso8601)] }
  end

  def expenses = Finance::Expense.where(incurred_on: from..to)
  def vendor_payments = Finance::VendorPayment.where(paid_on: from..to)

  # Stable across syncs: changes only when sales, payments, refunds, controls,
  # retained originals or money-out records for the period change.
  def digest
    @digest ||= Digest::SHA256.hexdigest({
      version: 1, kind: kind, from: from.iso8601, to: to.iso8601,
      days: workflows.map { |day, wf| [day.iso8601, wf.report.digest] },
      expenses: expenses.order(:id).pluck(:id, :amount_cents, :category, :incurred_on, :vendor_id, :updated_at).map { |r| r.map(&:to_s) },
      vendor_payments: vendor_payments.order(:id).pluck(:id, :amount_cents, :paid_on, :vendor_id, :updated_at).map { |r| r.map(&:to_s) }
    }.to_json)
  end

  # Sales pools are never added across currency or source; each row stays separate.
  def pools
    @pools ||= workflows.values.flat_map { |wf| wf.report.register.rows }
      .group_by { |row| [row[:currency], row[:source], row[:location_id].presence] }
      .map do |(currency, source, location), rows|
        { currency: currency, source: source, location_id: location, orders: rows.sum { |r| r[:orders].to_i },
          order_total_cents: sum_known(rows.map { |r| r[:order_total_cents] }), tax_cents: sum_known(rows.map { |r| r[:tax_cents] }),
          cash_cents: sum_known(rows.map { |r| r[:tenders]&.fetch('cash', 0) }), card_cents: sum_known(rows.map { |r| r[:tenders]&.fetch('card', 0) }),
          refund_cents: sum_known(rows.map { |r| r[:refund_cents] }) }
      end.sort_by { |p| [p[:currency].to_s, p[:source].to_s, p[:location_id].to_s] }
  end

  def issues
    @issues ||= workflows.values.map(&:issues).each_with_object(Hash.new(0)) { |h, acc| h.each { |k, v| acc[k] += v.to_i } }
  end

  def issue_total = issues.values.sum

  def per_day
    workflows.map do |day, wf|
      rows = wf.report.register.rows
      { day: day, orders: rows.sum { |r| r[:orders].to_i }, issues: wf.issues.values.sum,
        review: wf.review && { status: wf.review.status, current: !!wf.review_current? } }
    end
  end

  def money_out
    { expenses_cents: expenses.sum(:amount_cents), expense_count: expenses.count,
      vendor_payments_cents: vendor_payments.sum(:amount_cents), vendor_payment_count: vendor_payments.count }
  end

  # Frozen into the approval record so history shows what was in front of the approver.
  def summary
    { 'label' => label, 'pools' => pools.map { |p| p.transform_keys(&:to_s) }, 'issues' => issues.transform_keys(&:to_s),
      'money_out' => money_out.transform_keys(&:to_s), 'digest' => digest }
  end

  def approvals
    BookApproval.for_period(kind, from).where(period_to: to).chronological.to_a
  end

  def latest_approval = approvals.last

  # :pending, :approved, :approved_with_exceptions, :needs_attention, or :changed
  # when the latest approval was for different evidence than is on file now.
  def state
    approval = latest_approval
    return :pending unless approval
    return :changed unless approval.report_digest == digest

    approval.status.to_sym
  end

  # A day-level view for the strip of recent days. Weekly approvals cover their days.
  def self.day_states(days)
    return {} if days.empty?

    approvals = BookApproval.where('period_from <= ? AND period_to >= ?', days.max, days.min).chronological.to_a
    current = {}
    days.index_with do |day|
      approval = approvals.select { |a| a.period_from <= day && a.period_to >= day }.max_by { |a| [a.approved_at, a.id] }
      next :pending unless approval

      key = [approval.period_kind, approval.period_from, approval.period_to]
      current[key] = new(kind: approval.period_kind, date: approval.period_from).digest == approval.report_digest unless current.key?(key)
      current[key] ? approval.status.to_sym : :changed
    end
  end

  private

  def sum_known(values)
    values.any?(&:nil?) ? nil : values.sum
  end
end
