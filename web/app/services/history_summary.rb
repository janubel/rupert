# frozen_string_literal: true

# One honest picture of the history Rupert retains, per source: the earliest and
# latest dates it holds, how many records, when it last arrived, the calendar
# months inside that span with nothing, and where sources overlap in time.
#
# Nothing is inferred. A source's oldest record is evidence of the coverage that
# was available, not proof of when the business began or that nothing older
# exists; a month with no records may be a quiet month or a gap. Counts are what
# Rupert stores, never a total of sales. Only dates and counts leave this class:
# no names, amounts or raw rows.
class HistorySummary
  GAP_LIMIT = 24
  ZONE = MoneyReconciliationReport::ZONE

  Source = Struct.new(:key, :label, :role, :unit, :first_date, :last_date, :records, :last_import_at, :gap_months, :gap_total,
    :overlaps, :caveat, :path, :detail, :by_year, :by_month, keyword_init: true)

  def self.call(today: Time.find_zone!(ZONE).today) = new(today: today).sources

  def initialize(today: Time.find_zone!(ZONE).today)
    @today = today
  end

  def sources
    @sources ||= begin
      built = definitions.map { |definition| build(definition) }
      add_overlaps(built)
    end
  end

  def years
    sources.flat_map { |source| source.by_year.keys }.uniq.sort
  end

  def to_h
    { generated_on: @today.iso8601, years: years, sources: sources.map { |source| source.to_h.except(:by_month).transform_values { |v| v.respond_to?(:iso8601) ? v.iso8601 : v } } }
  end

  private

  # key, label, role, unit, scope, date column, kind (:date or :time), last import, caveat, path
  def definitions
    [
      { key: 'quickbooks', label: 'QuickBooks', role: 'Imported accounting history (journal transactions)', unit: 'transactions',
        scope: ImportTransaction.where(status: %w[staged posted]), column: :txn_date, kind: :date,
        last_import: -> { ImportBatch.where(source: 'quickbooks').where.not(status: 'discarded').maximum(:created_at) },
        caveat: 'Staged transactions are read but not posted until a person approves them. The earliest date is the earliest in the files uploaded, not when the business began.',
        path: '/finance/quickbooks_imports', detail: -> { quickbooks_detail } },
      { key: 'shopify', label: 'Shopify', role: 'Online orders', unit: 'orders', scope: Core::Order.where(source: 'shopify'), column: :occurred_at, kind: :time,
        last_import: -> { CatalogSyncHistory.watermark('shopify') },
        caveat: 'Reach depends on the access the Shopify app was granted; an older order than the oldest shown may exist at the source.', path: '/orders' },
      { key: 'square', label: 'Square', role: 'POS orders', unit: 'orders', scope: Core::Order.where(source: 'square'), column: :occurred_at, kind: :time,
        last_import: -> { CatalogSyncHistory.watermark('square') },
        caveat: 'Locations that are now inactive may hold older history that routine syncs do not read.', path: '/orders' },
      { key: 'ctrax', label: 'C-Trax', role: 'Retail sales and register controls', unit: 'store-day snapshots', scope: CtraxDay.all, column: :business_date, kind: :date,
        last_import: -> { CtraxDay.maximum(:captured_at) },
        caveat: 'A day with no snapshot is not a claim of zero sales.', path: '/ctrax_days' },
      { key: 'swipesimple', label: 'SwipeSimple', role: 'Payment transactions', unit: 'transaction observations',
        scope: SwipesimpleReportRow.latest.where(swipesimple_exports: { kind: 'transactions' }), column: :occurred_at, kind: :time,
        last_import: -> { PosConnection.find_by(provider: 'swipesimple')&.last_reported_at },
        caveat: 'The vendor export is capped at 10,000 rows; larger history needs split ranges.', path: '/swipesimple_reports' },
      { key: 'iris', label: 'NAB / IRIS', role: 'Processor report snapshots', unit: 'report windows', scope: IrisReport.all, range: %i[window_from window_to], kind: :range,
        last_import: -> { IrisReport.maximum(:observed_at) },
        caveat: 'Report windows can overlap; they are snapshots, never summed and never sales.', path: '/money_reconciliations', detail: -> { iris_detail } },
      { key: 'authorize_net', label: 'Authorize.net', role: 'Gateway transactions', unit: 'transactions', scope: AuthorizeNetTransaction.all, column: :submitted_at, kind: :time,
        last_import: -> { AuthorizeNetTransaction.maximum(:created_at) },
        caveat: 'Portal snapshots do not establish API reporting access; only transactions Rupert holds are counted.', path: '/money_reconciliations' },
      { key: 'bank', label: 'Bank statements', role: 'Uploaded statement lines', unit: 'lines', scope: BankStatementLine.all, column: :posted_on, kind: :date,
        last_import: -> { BankStatementLine.maximum(:created_at) },
        caveat: 'Only statements someone uploaded; no live bank feed.', path: '/bank_statements' },
      { key: 'ledger', label: 'Rupert ledger', role: 'Journal entries made in Rupert (QuickBooks imports shown separately)', unit: 'entries',
        scope: Finance::JournalEntry.posted.where.not(kind: 'imported'), column: :posted_on, kind: :date,
        last_import: -> { Finance::JournalEntry.where.not(kind: 'imported').maximum(:created_at) },
        caveat: 'Posting of sales and vendor payments is partial today; see the ledger posting plan.', path: '/finance/journal_entries' },
      { key: 'order_mirror', label: 'Imported orders mirror', role: 'Recent-orders mirror (not an archive)', unit: 'entries', scope: LedgerEntry.all, column: :occurredAt, kind: :time,
        last_import: -> { LedgerEntry.maximum(:syncedAt) },
        caveat: 'A 365-day derived mirror. Older orders live in the order records above; do not read this as history.', path: '/ledger' }
    ]
  end

  def build(definition)
    scope = definition[:scope]
    months = definition[:kind] == :range ? range_months(scope, *definition[:range]) : month_counts(scope, definition[:column])
    first_month, last_month = months.keys.minmax
    first_date, last_date = if definition[:kind] == :range
      [scope.minimum(definition[:range][0]), scope.maximum(definition[:range][1])]
    else
      [scope.minimum(definition[:column]), scope.maximum(definition[:column])]
    end
    gaps = first_month ? gap_months(first_month, last_month, months) : []
    Source.new(
      key: definition[:key], label: definition[:label], role: definition[:role], unit: definition[:unit], records: scope.count,
      first_date: to_date(first_date), last_date: to_date(last_date), last_import_at: definition[:last_import]&.call, gap_months: gaps.first(GAP_LIMIT), gap_total: gaps.size,
      overlaps: [], caveat: definition[:caveat], path: definition[:path], detail: definition[:detail] ? instance_exec(&definition[:detail]) : nil,
      by_month: months, by_year: months.group_by { |month, _| month.first(4) }.transform_values { |rows| rows.sum { |_, count| count } }.sort.to_h
    )
  rescue ActiveRecord::StatementInvalid => e
    Rails.error.report(e, handled: true, context: { history_source: definition[:key] })
    Source.new(key: definition[:key], label: definition[:label], role: definition[:role], unit: definition[:unit], records: 0, gap_months: [], gap_total: 0, overlaps: [],
      caveat: 'This source could not be read just now.', path: definition[:path], by_year: {}, by_month: {})
  end

  # Calendar months of the stored value (time stamps are bucketed by their
  # stored UTC date, so a record near midnight at a month end can land in the
  # neighbouring month; first and last dates are converted to the store zone).
  def month_counts(scope, column)
    connection = scope.klass.connection
    qualified = "#{connection.quote_table_name(scope.klass.table_name)}.#{connection.quote_column_name(column)}"
    scope.reorder(nil).group(Arel.sql("strftime('%Y-%m', #{qualified})")).count.compact.sort.to_h
  end

  def range_months(scope, from_column, to_column)
    scope.distinct.pluck(from_column, to_column).each_with_object(Hash.new(0)) do |(from, to), counts|
      (from..to).map { |day| day.strftime('%Y-%m') }.uniq.each { |month| counts[month] += 1 }
    end.sort.to_h
  end

  def gap_months(first_month, last_month, counts)
    month = Date.strptime(first_month, '%Y-%m')
    last = Date.strptime(last_month, '%Y-%m')
    gaps = []
    while month <= last
      key = month.strftime('%Y-%m')
      gaps << key unless counts.key?(key)
      month = month.next_month
    end
    gaps
  end

  def to_date(value)
    return nil if value.nil?

    (value.respond_to?(:in_time_zone) && !value.is_a?(Date) ? value.in_time_zone(ZONE).to_date : value.to_date)
  end

  # Where the time spans of two sources coincide. A span overlap says nothing
  # about whether the records agree; the reconciliation panel compares those.
  def add_overlaps(rows)
    rows.each do |row|
      next unless row.first_date && row.last_date

      row.overlaps = rows.filter_map do |other|
        next if other.equal?(row) || other.first_date.nil? || other.key == 'order_mirror' || row.key == 'order_mirror'

        from = [row.first_date, other.first_date].max
        to = [row.last_date, other.last_date].min
        { 'key' => other.key, 'label' => other.label, 'from' => from.iso8601, 'to' => to.iso8601 } if from <= to
      end
    end
    rows
  end

  def quickbooks_detail
    batches = ImportBatch.where(source: 'quickbooks')
    {
      'batches' => batches.group(:status).count,
      'posted_transactions' => ImportTransaction.where(status: 'posted').count,
      'staged_transactions' => ImportTransaction.where(status: 'staged').count,
      'journal_entries_posted' => Finance::JournalEntry.posted.where(kind: 'imported').count
    }
  end

  def iris_detail
    windows = IrisReport.distinct.pluck(:merchant_number, :report_kind, :window_from, :window_to)
    overlapping = windows.group_by { |merchant, kind, *| [merchant, kind] }.sum do |_, rows|
      rows.sort_by { |row| row[2] }.each_cons(2).count { |a, b| b[2] <= a[3] }
    end
    { 'overlapping_window_pairs' => overlapping }
  end
end
