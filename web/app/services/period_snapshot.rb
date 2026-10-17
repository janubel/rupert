# frozen_string_literal: true

require 'digest'

# Totals of everything Rupert holds for a span of dates, grouped so nothing is
# added across source, currency or status, plus a stable fingerprint. Used when
# locking a month, quarter or year, and later to tell whether the locked
# records have changed. Read-only; unknown amounts stay out of sums rather
# than counting as zero.
class PeriodSnapshot
  LABELS = { 'orders' => 'Sales orders', 'payments' => 'Payments', 'refunds' => 'Refunds', 'expenses' => 'Expenses',
             'vendor_payments' => 'Vendor payments', 'bank_lines' => 'Bank statement lines', 'reviews' => 'Day reviews',
             'approvals' => 'Approvals', 'originals' => 'Retained originals' }.freeze

  attr_reader :from, :to

  def initialize(from:, to:)
    @from = from
    @to = to
    @range = Time.zone.local(from.year, from.month, from.day)...Time.zone.local((to + 1).year, (to + 1).month, (to + 1).day)
  end

  def totals
    @totals ||= {
      'from' => from.iso8601, 'to' => to.iso8601,
      'orders' => rows(Core::Order.where(occurred_at: @range).group(:source, :currency, :status)
        .pluck(:source, :currency, :status, Arel.sql('COUNT(*)'), Arel.sql('SUM(gross_cents)'), Arel.sql('SUM(tax_cents)'))),
      'payments' => rows(Core::Payment.joins(:order).where(paid_at: @range).group('orders.source', 'orders.currency', 'payments.status').pluck('orders.source', 'orders.currency', 'payments.status', Arel.sql('COUNT(*)'), Arel.sql('SUM(payments.amount_cents)'))),
      'refunds' => rows(Core::Refund.joins(:order).where(refunded_at: @range).group('orders.source', 'orders.currency', 'refunds.method').pluck('orders.source', 'orders.currency', 'refunds.method', Arel.sql('COUNT(*)'), Arel.sql('SUM(refunds.amount_cents)'))),
      'expenses' => rows(Finance::Expense.where(incurred_on: from..to).group(:category).pluck(:category, Arel.sql('COUNT(*)'), Arel.sql('SUM(amount_cents)'))),
      'vendor_payments' => rows(Finance::VendorPayment.where(paid_on: from..to).group(:vendor_id).pluck(:vendor_id, Arel.sql('COUNT(*)'), Arel.sql('SUM(amount_cents)'))),
      'bank_lines' => rows(BankStatementLine.where(posted_on: from..to).group(:status).pluck(:status, Arel.sql('COUNT(*)'), Arel.sql('SUM(amount_cents)'))),
      'reviews' => rows(DailyReconciliationReview.where(day: from..to).group(:status).pluck(:status, Arel.sql('COUNT(*)'))),
      'approvals' => rows(BookApproval.where(period_from: from..to, period_to: from..to).group(:period_kind, :status).pluck(:period_kind, :status, Arel.sql('COUNT(*)'))),
      'originals' => rows(ReconciliationDocument.where(period_from: from..to, period_to: from..to).where.not(kind: ReconciliationDocument::GENERATED_KINDS)
        .group(:source, :kind).pluck(:source, :kind, Arel.sql('COUNT(*)')))
    }
  end

  def fingerprint = Digest::SHA256.hexdigest(totals.to_json)

  # Section names (human labels) whose totals differ from an earlier snapshot.
  def changed_sections(previous)
    LABELS.filter_map { |key, label| label if previous.is_a?(Hash) && previous[key] != totals[key] }
  end

  private

  # Stringify and sort so the fingerprint does not depend on database order.
  def rows(values) = values.map { |row| row.map { |v| v.nil? ? nil : v.to_s } }.sort_by { |row| row.map(&:to_s) }
end
