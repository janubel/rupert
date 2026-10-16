# frozen_string_literal: true

require 'csv'
require 'digest'

# Sales, gateway observations and processor reports are separate evidence layers.
# Comparisons require an explicit source/currency/location and a dated control.
class DailyMoneyReconciliation
  attr_reader :day, :register

  def initialize(day: Date.current.iso8601)
    @day = ReconciliationEvidence.dates(day, day).first
    @register = DailyRegisterSummary.new(day: @day.iso8601)
  end

  def documents
    @documents ||= ReconciliationDocument.covering(day).where.not(kind: 'daily_archive').order(:id).to_a
  end

  def controls
    superseded = documents.filter_map(&:supersedes_id)
    documents.select { |doc| doc.kind == 'register_control' && !superseded.include?(doc.id) }
  end

  def comparisons
    @comparisons ||= controls.group_by { |doc| [doc.source, doc.metadata['currency'], doc.metadata['location_id'].presence] }.flat_map do |(source, currency, location), evidence|
      if evidence.size > 1
        next [{ source: source, currency: currency, location_id: location, status: 'Conflicting controls', metric: 'control', document_ids: evidence.map(&:id) }]
      end
      doc = evidence.first
      row = register.rows.find { |r| r[:source] == source && r[:currency] == currency && r[:location_id].presence == location }
      actual = row ? { 'order_total' => row[:order_total_cents], 'cash' => row[:tenders].fetch('cash', 0),
        'card' => row[:tenders].fetch('card', 0), 'refunds' => row[:refund_cents] } : {}
      ReconciliationEvidence::AMOUNTS.filter_map do |metric|
        expected = doc.metadata[metric]
        next if expected.nil?
        observed = actual[metric]
        difference = observed.nil? ? nil : observed - expected
        { source: source, currency: currency, location_id: location, metric: metric,
          expected_cents: expected, actual_cents: observed, delta_cents: difference,
          status: difference.nil? ? 'Unavailable in canonical records' : (difference.zero? ? 'Matched recorded total' : 'Variance'), document_ids: [doc.id] }
      end
    end
  end

  def swipesimple
    @swipesimple ||= SwipesimpleDailyReport.new(day: day.iso8601).totals.sort_by { |row| [row[:account].to_s, row[:currency].to_s, row[:tender].to_s] }
  end

  def iris
    @iris ||= IrisReport.where('window_from <= ? AND window_to >= ?', day, day).order(observed_at: :desc).limit(50).to_a
  end

  def gateway
    @gateway ||= AuthorizeNetTransaction.where(settled_at: day.beginning_of_day...(day + 1).beginning_of_day)
      .group(:environment, :gateway_id, :currency, :payment_status, :transaction_type)
      .pluck(:environment, :gateway_id, :currency, :payment_status, :transaction_type, Arel.sql('COUNT(*)'), Arel.sql('SUM(settled_amount)'))
      .sort_by { |row| row.first(5).map(&:to_s) }
  end

  # Portal files stay separate from API observations. Their submitted and
  # settlement timestamps are shown explicitly; amounts are not added to sales.
  def portal
    @portal ||= AuthorizeNetPortalExport.latest_records.select do |row|
      %w[submitted_at settled_at].any? { |key| row[key].present? && Time.iso8601(row[key]).in_time_zone.to_date == day }
    end.sort_by { |row| [row['gateway_id'], row['transaction_id']] }
  end

  def payload
    @payload ||= { version: 1, day: day.iso8601, timezone: Time.zone.name, register: register.rows,
      coverage: register.coverage, freshness: register.source_freshness, comparisons: comparisons,
      swipesimple: swipesimple, gateway_settlement_observations: gateway, portal_observations: portal,
      swipesimple_export_ids: SwipesimpleDailyReport.new(day: day.iso8601).transactions.distinct.pluck(:swipesimple_export_id).sort,
      iris: iris.map { |report| [report.id, report.report_kind, report.status, report.window_from, report.window_to, report.observed_at, Digest::SHA256.hexdigest(report.payload_json)] },
      documents: documents.map { |doc| [doc.id, doc.fingerprint] } }
  end

  def digest
    Digest::SHA256.hexdigest(payload.to_json)
  end

  def latest_review
    DailyReconciliationReview.where(day: day).order(id: :desc).first
  end

  def archive!(actor: nil)
    ReconciliationEvidence.retain!(bytes: csv, filename: "daily-reconciliation-#{day}.csv", source: 'rupert', kind: 'daily_archive',
      from: day.iso8601, to: day.iso8601, metadata: { 'report_digest' => digest }, actor: actor)
  end

  def csv
    CSV.generate do |csv|
      csv << ['Daily reconciliation', day.iso8601, Time.zone.name, 'Amounts in integer cents unless explicitly marked']
      csv << ['Report fingerprint', digest]
      csv << ['Sales, payments, gateways and processor reports are separate layers; do not add them together. Unknown amounts remain unavailable.']
      csv << ['Register source', 'Currency', 'Location', 'Orders', 'Order total cents', 'Recorded tax cents', 'Cash cents', 'Card cents', 'Refund cents', 'Net tenders cents', 'Missing payment orders', 'Incomplete payment orders', 'Overcovered payment orders', 'Unknown amount orders']
      register.rows.each do |row|
        csv << [safe(row[:source]), safe(row[:currency]), safe(row[:location_id]), row[:orders], amount(row[:order_total_cents]), amount(row[:tax_cents]),
          amount(row[:tenders].fetch('cash', 0)), amount(row[:tenders].fetch('card', 0)), amount(row[:refund_cents]), amount(row[:net_tender_cents]),
          *DailyRegisterSummary::COVERAGE_KEYS.map { |key| row[key] }]
      end
      csv << ['Coverage metric', 'Count']
      register.coverage.each { |key, value| csv << [key, value] }
      csv << ['Source', 'Latest source-confirmed import', 'Import mode', 'Latest order event', 'Latest payment event', 'Latest refund event', 'Older history limited']
      register.source_freshness.each do |source, state|
        csv << [safe(source), state[:finished_at]&.iso8601 || 'Unavailable', safe(state[:mode]),
          *%i[order_at payment_at refund_at].map { |key| state[key]&.iso8601 || 'Unavailable' }, state[:history_limited]]
      end
      csv << ['Control source', 'Currency', 'Location', 'Metric', 'Source total cents', 'Recorded cents', 'Difference cents', 'Status', 'Evidence IDs']
      comparisons.each { |row| csv << [safe(row[:source]), safe(row[:currency]), safe(row[:location_id]), row[:metric], amount(row[:expected_cents]), amount(row[:actual_cents]), amount(row[:delta_cents]), row[:status], row[:document_ids].join(',')] }
      csv << ['SwipeSimple account', 'Currency', 'Tender', 'Sale cents', 'Refund cents', 'Net cents', 'Sale tip cents', 'Refund tip cents', 'Excluded rows']
      swipesimple.each { |row| csv << [safe(row[:account]), safe(row[:currency]), safe(row[:tender]), row[:sale_cents], row[:refund_cents], row[:net_cents], amount(row[:sale_tip_cents]), amount(row[:refund_tip_cents]), row[:excluded_rows]] }
      csv << ['Gateway environment', 'Gateway ID', 'Currency', 'Status', 'Transaction type', 'Count', 'Settlement amount (currency units)']
      gateway.each { |row| csv << row.map { |value| value.is_a?(BigDecimal) ? value.to_s('F') : safe(value) } }
      csv << ['Portal gateway', 'Transaction ID', 'Currency', 'Status', 'Type', 'Submitted at', 'Settled at', 'Settlement cents', 'Export ID']
      portal.each { |row| csv << %w[gateway_id transaction_id currency status transaction_type submitted_at settled_at settlement_cents export_id].map { |key| safe(row[key]) } }
      csv << ['IRIS snapshot ID', 'Kind', 'Status', 'From', 'To', 'Observed at', 'Overlapping snapshots must not be summed; batch amounts are not net bank funding']
      iris.each { |row| csv << [row.id, row.report_kind, row.status, row.window_from, row.window_to, row.observed_at.iso8601] }
      csv << ['Evidence ID', 'Source', 'Kind', 'From', 'To', 'Filename', 'SHA256', 'Supersedes ID', 'Source context and entered amounts (integer cents)']
      documents.each { |doc| csv << [doc.id, doc.source, doc.kind, doc.period_from, doc.period_to, safe(doc.filename), doc.sha256, doc.supersedes_id, safe(doc.metadata.to_json)] }
      csv << ['Source import status does not prove this day is complete. Tips, fees and deposits require source evidence when unavailable in canonical records.']
    end
  end

  private

  def amount(value)
    value.nil? ? 'Unavailable' : value
  end

  def safe(value)
    text = value.to_s
    text.match?(/\A\s*[=+\-@]/) ? "'#{text}" : text
  end
end
