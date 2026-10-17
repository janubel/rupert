# frozen_string_literal: true

require 'bigdecimal'

module Finance
  # Current, all-history evidence checks. These are separate from dated saved
  # reviews and never certify funding or change source/accounting records.
  class ReconciliationFindings
    LIMIT = 100
    attr_reader :generated_at

    def initialize
      @generated_at = Time.current
    end

    def square_missing
      @square_missing ||= Core::Order.where(source: 'square', status: %w[paid fulfilled refunded])
        .where('gross_cents > 0').where.not(id: Core::Payment.completed.select(:order_id))
        .order(:occurred_at, :id)
    end

    def unpaid_invoices
      @unpaid_invoices ||= SwipesimpleReportRow.latest.where(swipesimple_exports: { kind: 'invoices' }, status: 'unpaid')
        .includes(:swipesimple_export).order(:occurred_at, :id).to_a
    end

    def invoice_groups
      unpaid_invoices.group_by { |row| [row.swipesimple_export.merchant_account, row.swipesimple_export.currency] }
        .map do |(account, currency), rows|
          { account: account, currency: currency, count: rows.size,
            cents: rows.any? { |row| row.amount_cents.nil? } ? nil : rows.sum(&:amount_cents) }
        end
    end

    def bank_accounts
      @bank_accounts ||= BankStatementLine.group(:account_label).pluck(:account_label, Arel.sql('COUNT(*)'),
        Arel.sql('MIN(posted_on)'), Arel.sql('MAX(posted_on)'))
    end

    def ctrax_controls
      @ctrax_controls ||= begin
        summary = { days: 0, checks: 0, matched: 0, different: 0, unknown: 0 }
        CtraxDay.find_each do |day|
          summary[:days] += 1
          Ctrax::Reconciliation.new(day).checks.each do |check|
            summary[:checks] += 1
            key = check[:delta].nil? ? :unknown : (check[:delta].zero? ? :matched : :different)
            summary[key] += 1
          end
        end
        summary
      end
    end

    def iris_controls
      @iris_controls ||= begin
        reports = IrisReport.where(status: 'complete', report_kind: 'daily_deposits_csv').to_a
        # Whole native month snapshots only; no overlapping windows or Health
        # Center summaries are combined into this control check.
        reports.select! { |r| r.window_from == r.window_from.beginning_of_month && r.window_to == r.window_from.end_of_month }
        selected = reports.group_by { |r| [r.api_origin, r.merchant_number, r.window_from] }
          .values.map { |rows| rows.max_by { |r| [r.observed_at, r.id] } }
        summary = { reports: selected.size, matched: 0, different: 0, unknown: 0 }
        selected.each do |report|
          data = report.payload
          amounts = data.fetch('data', []).map { |row| decimal(row['amount']) }
          expected = decimal(data.dig('totals', 'amount'))
          key = if expected.nil? || amounts.any?(&:nil?)
            :unknown
          else
            amounts.sum(BigDecimal('0')) == expected ? :matched : :different
          end
          summary[key] += 1
        end
        summary
      end
    end

    private

    def decimal(value)
      BigDecimal(value.to_s, exception: false)&.then { |number| number.finite? ? number : nil }
    end
  end
end
