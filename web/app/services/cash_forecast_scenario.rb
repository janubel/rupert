# frozen_string_literal: true

require 'csv'

# Explicit bank-cash assumptions only. Never treats sales/tenders as bank funding.
class CashForecastScenario
  attr_reader :as_of, :currency, :horizon, :opening_cents, :reserve_cents, :basis, :notes, :rows

  def initialize(values)
    values = values.deep_stringify_keys
    @as_of = ReconciliationEvidence.dates(values['as_of'], values['as_of']).first
    @currency = values['currency'].to_s.strip.upcase
    raise ReconciliationEvidence::Error, 'Enter a three-letter currency for this scenario.' unless currency.match?(/\A[A-Z]{3}\z/)
    raise ReconciliationEvidence::Error, 'Choose 4, 8 or 13 forecast weeks.' unless %w[4 8 13].include?(values['horizon'].to_s)
    @horizon = values['horizon'].to_i
    @opening_cents = required_amount(values['opening'], 'Opening cash')
    @reserve_cents = ReconciliationEvidence.cents(values['reserve'])
    raise ReconciliationEvidence::Error, 'Minimum reserve must be zero or positive.' if reserve_cents&.negative?
    @basis = values['basis']
    raise ReconciliationEvidence::Error, 'Identify whether opening cash is an entered bank balance or an assumption.' unless %w[entered_balance assumption].include?(basis)
    @notes = values['notes'].to_s.strip
    raise ReconciliationEvidence::Error, 'Describe the scenario assumptions in 1 to 4000 characters.' unless notes.length.between?(1, 4000)
    balance = opening_cents
    @rows = horizon.times.map do |index|
      week = values.fetch('weeks', {})[index.to_s] || {}
      receipts = required_amount(week['receipts'], "Week #{index + 1} bank receipts", positive: true)
      payments = required_amount(week['payments'], "Week #{index + 1} payments", positive: true)
      opening = balance
      balance += receipts - payments
      { week: index + 1, from: as_of + 1 + index * 7, to: as_of + (index + 1) * 7,
        opening_cents: opening, receipts_cents: receipts, payments_cents: payments, closing_cents: balance }
    end
  end

  def first_shortfall
    ([{ week: 0, to: as_of, closing_cents: opening_cents }] + rows).find { |row| row[:closing_cents] < (reserve_cents || 0) }
  end

  def payload(baseline_digest:)
    { version: 1, type: 'manual_cash_forecast', as_of: as_of, currency: currency, horizon_weeks: horizon,
      opening_cents: opening_cents, opening_basis: basis, minimum_reserve_cents: reserve_cents, assumptions: notes,
      baseline_report_digest: baseline_digest, rows: rows,
      limitations: ['Manual planning scenario; inputs are not imported bank balances or predicted settlement.',
        'Weekly closing balances do not model intraday funding delays.', 'No currency conversion or combination is performed.'] }
  end

  def retain!(baseline_digest:, actor:)
    ReconciliationEvidence.retain!(bytes: payload(baseline_digest: baseline_digest).to_json,
      filename: "cash-forecast-#{as_of}-#{currency}-#{horizon}w.json", source: 'rupert', kind: 'cash_forecast',
      from: (as_of + 1).iso8601, to: rows.last[:to].iso8601,
      metadata: { as_of: as_of.iso8601, currency: currency, horizon_weeks: horizon, baseline_report_digest: baseline_digest }, actor: actor)
  end

  def csv
    CSV.generate do |out|
      out << ['Manual cash forecast', as_of.iso8601, currency, 'Integer cents; user-entered assumptions']
      out << ['Opening basis', basis, 'Minimum reserve cents', reserve_cents]
      note = notes.match?(/\A[\s]*[=+@-]/) || notes.match?(/\A[\t\r]/) ? "'#{notes}" : notes
      out << ['Assumptions', note]
      out << ['Week', 'From', 'Through', 'Opening cents', 'Bank receipts cents', 'Payments cents', 'Closing cents']
      rows.each { |row| out << row.values }
    end
  end

  private

  def required_amount(value, label, positive: false)
    amount = ReconciliationEvidence.cents(value)
    raise ReconciliationEvidence::Error, "#{label}: enter an explicit amount, including 0 when none is planned." if amount.nil?
    raise ReconciliationEvidence::Error, "#{label} must be zero or positive." if positive && amount.negative?

    amount
  end
end
