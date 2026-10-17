# frozen_string_literal: true

require 'csv'

# Explicit bank-cash assumptions only. Never treats sales/tenders as bank funding.
# Blank weekly amounts count as 0 for the preview, but are listed and must be
# confirmed (by exact entry list) before a CSV or retained version contains them.
class CashForecastScenario
  # A validation error tied to one form field id, so the view can mark and link it.
  class FieldError < ReconciliationEvidence::Error
    attr_reader :field

    def initialize(message, field)
      super(message)
      @field = field
    end
  end

  FIELDS = { 'receipts' => 'bank receipts', 'payments' => 'payments' }.freeze
  attr_reader :as_of, :currency, :horizon, :opening_cents, :reserve_cents, :basis, :notes, :rows, :blank_entries

  def self.retained(limit: 50)
    ReconciliationDocument.where(kind: 'cash_forecast', source: 'rupert').order(created_at: :desc, id: :desc).limit(limit)
  end

  # Values from the latest retained scenario in this currency. Weekly amounts are
  # carried only when the new close date is a whole number of weeks later, so
  # each amount keeps its calendar week; opening cash only for the same date.
  def self.prefill(as_of:, currency:)
    doc = retained.find { |item| item.metadata['currency'] == currency }
    return unless doc

    data = JSON.parse(doc.original_bytes)
    from = Date.iso8601(data['as_of'])
    days = (as_of - from).to_i
    shift = days >= 0 && (days % 7).zero? ? days / 7 : nil
    blanks = Array(data['blank_entries_confirmed_as_zero']).map { |entry| [entry['week'], entry['field']] }
    values = { 'horizon' => data['horizon_weeks'].to_s, 'reserve' => units(data['minimum_reserve_cents']), 'notes' => data['assumptions'], 'weeks' => {} }
    values.merge!('opening' => units(data['opening_cents']), 'basis' => data['opening_basis']) if days.zero?
    data['rows'].each do |row|
      index = row['week'] - 1 - shift.to_i
      next if shift.nil? || index.negative?

      values['weeks'][index.to_s] = FIELDS.keys.to_h { |field| [field, blanks.include?([row['week'], field]) ? '' : units(row["#{field}_cents"])] }
    end
    { document: doc, as_of: from, days: days, shift: shift, values: values.compact }
  rescue JSON::ParserError, Date::Error, KeyError, NoMethodError, TypeError
    nil
  end

  def self.units(cents)
    cents && format('%s%d.%02d', cents.negative? ? '-' : '', cents.abs / 100, cents.abs % 100)
  end

  def initialize(values)
    values = values.deep_stringify_keys
    @as_of = field('forecast_as_of') { ReconciliationEvidence.dates(values['as_of'], values['as_of']).first }
    @currency = values['currency'].to_s.strip.upcase
    raise FieldError.new('Enter a three-letter currency for this scenario.', 'forecast_currency') unless currency.match?(/\A[A-Z]{3}\z/)
    raise FieldError.new('Choose 4, 8 or 13 forecast weeks.', 'forecast_horizon') unless %w[4 8 13].include?(values['horizon'].to_s)

    @horizon = values['horizon'].to_i
    @opening_cents = amount(values['opening'], 'Opening cash', 'forecast_opening')
    raise FieldError.new('Opening cash: enter an explicit amount, including 0 when the account is empty.', 'forecast_opening') if opening_cents.nil?

    @reserve_cents = amount(values['reserve'], 'Minimum reserve', 'forecast_reserve')
    raise FieldError.new('Minimum reserve must be zero or positive.', 'forecast_reserve') if reserve_cents&.negative?

    @basis = values['basis']
    raise FieldError.new('Identify whether opening cash is an entered bank balance or an assumption.', 'forecast_basis') unless %w[entered_balance assumption].include?(basis)

    @notes = values['notes'].to_s.strip
    raise FieldError.new('Describe the scenario assumptions in 1 to 4000 characters.', 'forecast_notes') unless notes.length.between?(1, 4000)

    @blank_entries = []
    balance = opening_cents
    @rows = horizon.times.map do |index|
      week = values.fetch('weeks', {})[index.to_s] || {}
      receipts, payments = FIELDS.map do |key, label|
        id = "forecast_weeks_#{index}_#{key}"
        cents = amount(week[key], "Week #{index + 1} #{label}", id)
        raise FieldError.new("Week #{index + 1} #{label} must be zero or positive.", id) if cents&.negative?

        next cents if cents

        @blank_entries << { week: index + 1, field: key }
        0
      end
      opening = balance
      balance += receipts - payments
      { week: index + 1, from: as_of + 1 + index * 7, to: as_of + (index + 1) * 7,
        opening_cents: opening, receipts_cents: receipts, payments_cents: payments, closing_cents: balance }
    end
  end

  def receipts_cents = rows.sum { |row| row[:receipts_cents] }
  def payments_cents = rows.sum { |row| row[:payments_cents] }

  # Names the exact blank entries, so a confirmation cannot carry over to a changed plan.
  def zero_confirmation_key
    blank_entries.map { |entry| "#{entry[:week]}:#{entry[:field]}" }.join(',')
  end

  def zeros_confirmed?(confirmation)
    blank_entries.empty? || confirmation.to_s == zero_confirmation_key
  end

  def first_shortfall
    ([{ week: 0, to: as_of, closing_cents: opening_cents }] + rows).find { |row| row[:closing_cents] < (reserve_cents || 0) }
  end

  def shortfall_cents
    first_shortfall ? (reserve_cents || 0) - first_shortfall[:closing_cents] : 0
  end

  def payload(baseline_digest:, prefilled_from: nil)
    { version: 2, type: 'manual_cash_forecast', as_of: as_of, currency: currency, horizon_weeks: horizon,
      opening_cents: opening_cents, opening_basis: basis, minimum_reserve_cents: reserve_cents, assumptions: notes,
      baseline_report_digest: baseline_digest, rows: rows, blank_entries_confirmed_as_zero: blank_entries,
      prefilled_from_document_id: prefilled_from,
      limitations: ['Manual planning scenario; inputs are not imported bank balances or predicted settlement.',
        'Weekly closing balances do not model intraday funding delays.', 'No currency conversion or combination is performed.'] }
  end

  def retain!(baseline_digest:, actor:, zero_confirmation: nil, prefilled_from: nil)
    raise ReconciliationEvidence::Error, 'Confirm the blank weekly entries that will be saved as 0.' unless zeros_confirmed?(zero_confirmation)

    ReconciliationEvidence.retain!(bytes: payload(baseline_digest: baseline_digest, prefilled_from: prefilled_from).to_json,
      filename: "cash-forecast-#{as_of}-#{currency}-#{horizon}w.json", source: 'rupert', kind: 'cash_forecast',
      from: (as_of + 1).iso8601, to: rows.last[:to].iso8601,
      metadata: { as_of: as_of.iso8601, currency: currency, horizon_weeks: horizon, baseline_report_digest: baseline_digest,
        blank_entries_confirmed_as_zero: blank_entries, prefilled_from_document_id: prefilled_from }, actor: actor)
  end

  def csv
    CSV.generate do |out|
      out << ['Manual cash forecast', as_of.iso8601, currency, 'Integer cents; user-entered assumptions']
      out << ['Opening basis', basis, 'Minimum reserve cents', reserve_cents]
      note = notes.match?(/\A[\s]*[=+@-]/) || notes.match?(/\A[\t\r]/) ? "'#{notes}" : notes
      out << ['Assumptions', note]
      out << ['Blank entries confirmed as 0', blank_entries.map { |entry| "Week #{entry[:week]} #{FIELDS[entry[:field]]}" }.join('; ').presence || 'None']
      out << ['Week', 'From', 'Through', 'Opening cents', 'Bank receipts cents', 'Payments cents', 'Closing cents']
      rows.each { |row| out << row.values }
      out << ['Total', rows.first[:from], rows.last[:to], opening_cents, receipts_cents, payments_cents, rows.last[:closing_cents]]
    end
  end

  private

  def field(id)
    yield
  rescue ReconciliationEvidence::Error => e
    raise FieldError.new(e.message, id)
  end

  def amount(value, label, id)
    ReconciliationEvidence.cents(value)
  rescue ReconciliationEvidence::Error => e
    raise FieldError.new("#{label}: #{e.message.sub(/\A[A-Z][a-z]*: /, '')}", id)
  end
end
