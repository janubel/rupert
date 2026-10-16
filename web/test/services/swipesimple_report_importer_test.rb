# frozen_string_literal: true

require 'test_helper'

class SwipesimpleReportImporterTest < ActiveSupport::TestCase
  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    @options = { kind: 'transactions', merchant_account: 'Example Wholesale', currency: 'USD',
      source_timezone: 'America/New_York', exported_at: '2026-10-15T22:00:00-04:00' }
    travel_to Time.iso8601('2026-10-16T03:00:00Z')
  end

  teardown do
    travel_back
    Current.reset
  end

  test 'vendor-generated transaction and invoice formats validate without business writes or private preview values' do
    assert_no_difference ['SwipesimpleExport.count', 'Core::Order.count', 'Core::Payment.count', 'LedgerEntry.count', 'SyncRun.count'] do
      prepared = SwipesimpleReportImporter.preview(fixture('transactions'), @options)
      assert_equal 13, prepared.rows.length
      assert_equal 1, prepared.rows.count { |row| row[:transaction_type] == 'Refund' }
      refute_includes prepared.summary.to_json, 'Fictional Customer'
      refute_includes prepared.summary.to_json, 'DEMO-'
      invoices = SwipesimpleReportImporter.preview(fixture('invoices'), @options.merge(kind: 'invoices', invoice_scope: 'full'))
      assert_equal 7, invoices.rows.length
      assert_includes invoices.rows.pluck(:status), 'marked as paid'
      assert invoices.rows.all? { |row| row[:tender].nil? }
    end
  end

  test 'exact replay is unchanged and preserves exact encrypted document provenance' do
    csv = fixture('transactions')
    receipt = import(csv)
    assert_equal Digest::SHA256.hexdigest(csv.b), receipt.sha256
    assert_equal csv, receipt.reload.original_csv
    assert_equal 2, receipt.report_rows.first.source_row
    assert_no_difference ['SwipesimpleExport.count', 'SwipesimpleReportRow.count', 'Core::Order.count'] do
      assert_equal receipt.id, import(csv).id
    end
    raw = SwipesimpleExport.connection.select_value("SELECT original_csv FROM swipesimple_exports WHERE id = #{receipt.id}")
    refute_includes raw, 'Fictional Customer'
    assert_equal 13, SwipesimpleReportRow.latest.count
  end

  test 'sale and refund sharing a source number are distinct and overlapping exports do not double count' do
    import(fixture('transactions'))
    import(fixture('transactions'), @options.merge(exported_at: '2026-10-15T23:00:00-04:00'))
    assert_equal 26, SwipesimpleReportRow.count
    assert_equal 13, SwipesimpleReportRow.latest.count
    numbers = SwipesimpleReportRow.latest.group_by(&:source_number)
    pair = numbers.values.find { |rows| rows.length == 2 }
    assert_equal %w[Refund Sale], pair.pluck(:transaction_type).sort
  end

  test 'newer void evidence replaces approved totals and late old files cannot revive it' do
    csv = single_transaction
    old_options = @options.merge(exported_at: '2026-10-15T20:00:00-04:00')
    import(csv.sub('Approved', 'Voided'))
    import(csv, old_options)
    report = SwipesimpleDailyReport.new(day: '2026-10-14')
    assert_equal 0, report.totals.sum { |row| row[:sale_cents] }
    assert_equal 1, report.totals.sum { |row| row[:excluded_rows] }
    assert_equal 'Voided', report.transactions.first.status
    assert_equal 2, SwipesimpleExport.count
  end

  test 'daily totals use event dates retain missing tips and never add invoices' do
    import(single_transaction)
    import(fixture('invoices'), @options.merge(kind: 'invoices', invoice_scope: 'full'))
    report = SwipesimpleDailyReport.new(day: '2026-10-14')
    row = report.totals.first
    assert_equal 4800, row[:sale_cents]
    assert_equal 'card', row[:tender]
    assert_nil row[:sale_tip_cents]
    assert_equal 1, row[:missing_tip_rows]
    with_tip = CSV.parse(single_transaction, headers: true)
    text = CSV.generate do |csv|
      csv << with_tip.headers + ['Tip Amount']
      csv << with_tip.first.fields + ['$3.00']
    end
    import(text, @options.merge(exported_at: '2026-10-15T23:00:00-04:00'))
    row = SwipesimpleDailyReport.new(day: '2026-10-14').totals.first
    assert_equal 300, row[:sale_tip_cents]
    assert_equal 4800, row[:sale_cents]
  end

  test 'invoice payment result is preserved separately and can change across snapshots' do
    source = fixture('invoices')
    import(source, @options.merge(kind: 'invoices', invoice_scope: 'full'))
    import(source.sub(',unpaid,', ',paid,'), @options.merge(kind: 'invoices', invoice_scope: 'full', exported_at: '2026-10-15T23:00:00-04:00'))
    assert_equal 7, SwipesimpleReportRow.latest.count
    assert_equal 'paid', SwipesimpleReportRow.latest.find { |row| row.source_number == 'INV-1' }.status
    assert_equal 0, Core::Order.where(source: 'swipesimple').count
  end

  test 'duplicate invoice numbers remain distinct rows in full snapshots and filtered snapshots are rejected' do
    source = fixture('invoices').sub('INV-2,', 'INV-1,')
    import(source, @options.merge(kind: 'invoices', invoice_scope: 'full'))
    assert_equal 2, SwipesimpleReportRow.latest.count { |row| row.source_number == 'INV-1' }
    assert_equal 7, SwipesimpleReportRow.latest.count
    assert_raises(SwipesimpleReportImporter::Error) do
      SwipesimpleReportImporter.preview(source, @options.merge(kind: 'invoices'))
    end
    import(source.lines.first(2).join, @options.merge(kind: 'invoices', invoice_scope: 'full', exported_at: '2026-10-15T23:00:00-04:00'))
    assert_equal 1, SwipesimpleReportRow.latest.count
    assert_equal 8, SwipesimpleReportRow.count
  end

  test 'a confirmed empty full invoice snapshot clears current observations but preserves prior evidence' do
    import(fixture('invoices'), @options.merge(kind: 'invoices', invoice_scope: 'full'))
    import(fixture('invoices').lines.first, @options.merge(kind: 'invoices', invoice_scope: 'full', exported_at: '2026-10-15T23:00:00-04:00'))
    assert_equal 0, SwipesimpleReportRow.latest.count
    assert_equal 7, SwipesimpleReportRow.count
  end

  test 'equal-time conflicts changed context and invalid later rows roll back the entire import' do
    receipt = import(single_transaction)
    assert_no_difference ['SwipesimpleExport.count', 'SwipesimpleReportRow.count'] do
      assert_raises(SwipesimpleReportImporter::Error) { import(single_transaction.sub('$48.00', '$49.00')) }
      assert_raises(SwipesimpleReportImporter::Error) { import(single_transaction, @options.merge(source_timezone: 'America/Chicago')) }
      prepared = SwipesimpleReportImporter.preview(single_transaction, @options)
      assert_raises(SwipesimpleReportImporter::Error) do
        SwipesimpleReportImporter.import!(single_transaction.sub('$48.00', '$49.00'), @options, expected_fingerprint: prepared.fingerprint)
      end
      assert_raises(SwipesimpleReportImporter::Error) { import(fixture('transactions').sub('$26.00', 'SECRET_INVALID')) }
    end
    assert_equal 4800, receipt.report_rows.first.amount_cents
  end

  test 'tenant and account identities are separate and no cross-tenant rows appear' do
    first = import(single_transaction)
    other = Tenant.create!(name: 'Other reporting', subdomain: 'other-reporting')
    Current.tenant = other
    second = import(single_transaction)
    assert_not_equal first.id, second.id
    assert_equal 1, SwipesimpleReportRow.latest.count
    assert_equal [second.id], SwipesimpleReportRow.latest.pluck(:swipesimple_export_id)
    assert_nil SwipesimpleExport.find_by(id: first.id)
  end

  test 'native context money dates headers identities and limits fail without echoing source data' do
    sources = [single_transaction.sub('$48.00', '-48.00'), single_transaction.sub('$48.00', '48.001'),
      single_transaction.sub('Approved', 'SECRET_PRIVATE'), single_transaction.sub('10/14/2026 8:27 PM', '02/30/2026 8:27 PM'),
      single_transaction.sub('10/14/2026 8:27 PM', '11/01/2026 1:30 AM'),
      single_transaction.sub('10/14/2026 8:27 PM', '03/08/2026 2:30 AM'),
      single_transaction.sub('Transaction #', 'Transaction ID'), single_transaction.sub('Example Wholesale', 'SECRET_PRIVATE'),
      single_transaction + single_transaction.lines.last]
    sources.each do |csv|
      error = assert_raises(SwipesimpleReportImporter::Error) { SwipesimpleReportImporter.preview(csv, @options) }
      refute_includes error.message, 'SECRET_PRIVATE'
    end
    [@options.merge(currency: 'CAD'), @options.merge(source_timezone: 'SECRET_PRIVATE'),
      @options.merge(exported_at: '2026-10-15'), @options.merge(exported_at: '2026-12-01T00:00:00Z')].each do |options|
      assert_raises(SwipesimpleReportImporter::Error) { SwipesimpleReportImporter.preview(single_transaction, options) }
    end
    assert_raises(SwipesimpleReportImporter::Error) { SwipesimpleReportImporter.preview('x' * (SwipesimpleReportImporter::MAX_BYTES + 1), @options) }
  end

  test 'non-card invoice payment methods remain unknown when no card evidence is exported' do
    table = CSV.parse(single_transaction, headers: true)
    row = table.first.to_h.merge('Method' => 'Invoice', 'Brand' => '', 'Auth Code' => '')
    text = CSV.generate do |csv|
      csv << table.headers
      csv << row.values
    end
    assert_equal 'unknown', SwipesimpleReportImporter.preview(text, @options).rows.first[:tender]
  end

  private

  def fixture(kind)
    File.read(Rails.root.join("test/fixtures/files/swipesimple_#{kind}.csv"))
  end

  def single_transaction
    fixture('transactions').lines.first(2).join
  end

  def import(csv, options = @options)
    prepared = SwipesimpleReportImporter.preview(csv, options)
    SwipesimpleReportImporter.import!(csv, options, expected_fingerprint: prepared.fingerprint)
  end
end
