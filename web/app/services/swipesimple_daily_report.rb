# frozen_string_literal: true

class SwipesimpleDailyReport
  attr_reader :day

  def initialize(day: Date.current.iso8601)
    raise ArgumentError unless day.to_s.match?(/\A\d{4}-\d{2}-\d{2}\z/)
    @day = Date.iso8601(day)
  end

  def transactions
    from = Time.zone.local(day.year, day.month, day.day)
    SwipesimpleReportRow.latest.where(swipesimple_exports: { kind: 'transactions' })
      .where(occurred_at: from...from + 1.day)
  end

  def totals
    transactions.includes(:swipesimple_export).group_by do |row|
      [row.swipesimple_export.merchant_account, row.swipesimple_export.currency, row.tender]
    end.map do |(account, currency, tender), rows|
      approved = rows.select { |row| row.status == 'Approved' }
      sales = approved.select { |row| row.transaction_type == 'Sale' }
      refunds = approved.select { |row| row.transaction_type == 'Refund' }
      { account: account, currency: currency, tender: tender,
        sale_cents: sales.sum(&:amount_cents), refund_cents: refunds.sum(&:amount_cents),
        net_cents: sales.sum(&:amount_cents) - refunds.sum(&:amount_cents),
        sale_tip_cents: sales.all? { |row| row.tip_cents } ? sales.sum(&:tip_cents) : nil,
        refund_tip_cents: refunds.all? { |row| row.tip_cents } ? refunds.sum(&:tip_cents) : nil,
        missing_tip_rows: approved.count { |row| row.tip_cents.nil? },
        excluded_rows: rows.length - approved.length }
    end
  end
end
