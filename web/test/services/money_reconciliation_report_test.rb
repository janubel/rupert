# frozen_string_literal: true

require 'test_helper'

class MoneyReconciliationReportTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
    travel_to Time.iso8601('2026-10-16T03:00:00Z')
  end

  teardown do
    travel_back
    Current.reset
  end

  test 'Eastern daily weekly and monthly boundaries preserve DST and completed periods' do
    order('before', '2026-03-08T04:59:59Z', 100)
    order('inside', '2026-03-08T05:00:00Z', 200)
    order('end', '2026-03-09T03:59:59Z', 300)
    order('after', '2026-03-09T04:00:00Z', 400)
    rows = report('daily', '2026-03-08').payload['rows'].select { |r| r['source'] == 'Shopify' }
    assert_equal 1, rows.size
    assert_equal 2, rows.first['count']
    assert_equal '5.0', rows.first['amount']
    weekly = report('weekly', '2026-10-15')
    assert_equal Date.new(2026, 10, 12), weekly.from
    assert_equal Date.new(2026, 10, 18), weekly.to
    assert_equal Date.new(2026, 9, 30), MoneyReconciliationReport.previous_period('monthly', today: Date.new(2026, 10, 1))
    assert_equal Date.new(2026, 10, 5), MoneyReconciliationReport.previous_period('weekly', today: Date.new(2026, 10, 15))
    quarterly = report('quarterly', '2026-10-15')
    assert_equal [Date.new(2026, 10, 1), Date.new(2026, 12, 31)], [quarterly.from, quarterly.to]
    yearly = report('yearly', '2026-10-15')
    assert_equal [Date.new(2026, 1, 1), Date.new(2026, 12, 31)], [yearly.from, yearly.to]
    assert_equal Date.new(2026, 9, 30), MoneyReconciliationReport.previous_period('quarterly', today: Date.new(2026, 10, 15))
    assert_equal Date.new(2025, 12, 31), MoneyReconciliationReport.previous_period('yearly', today: Date.new(2026, 10, 15))
    assert_raises(ArgumentError) { report('hourly', '2026-10-15') }
  end

  test 'sales gateway and deposits stay separate with unknown currency and no false bank match' do
    order('online', '2026-10-15T15:00:00Z', 4800)
    IrisReport.create!(api_origin: 'https://fixture.iriscrm.com', merchant_number: '123', report_kind: 'daily_deposits_csv',
      window_from: '2026-10-01', window_to: '2026-10-31', status: 'complete', observed_at: Time.current,
      payload_json: { 'currency' => nil, 'data' => [{ 'date' => '2026-10-15', 'amount' => '48.00' }] }.to_json)
    payload = report.payload
    assert_equal 'Review required', payload['status']
    assert_equal %w[Shopify NAB\ /\ IRIS], payload['rows'].pluck('source')
    bank = payload['rows'].last
    assert_nil bank['currency']
    assert_equal '48.0', bank['amount']
    refute payload.key?('grand_total')
    assert payload['warnings'].any? { |w| w.include?('currency') }
    assert payload['warnings'].any? { |w| w.include?('links are not yet established') }
  end

  test 'overlapping IRIS snapshots are selected per month rather than summed or prorated' do
    old = iris('2026-09-01', '2026-09-30', '2026-09-30', '11.00', observed: 1.day.ago)
    iris('2026-10-01', '2026-10-31', '2026-10-01', '20.00')
    iris('2026-09-28', '2026-10-04', '2026-09-30', '99.00', kind: 'deposits', observed: 2.days.ago)
    payload = report('weekly', '2026-10-01').payload
    bank = payload['rows'].select { |r| r['source'] == 'NAB / IRIS' }
    assert_equal 2, bank.size
    assert_equal ['11.0', '20.0'], bank.pluck('amount')
    old.update!(report_kind: 'sales_health_csv', payload_json: { data: [{ metric: 'gross_sales', value: '2000' }] }.to_json)
    refute report('weekly', '2026-10-01').payload['rows'].any? { |r| r['metric'].include?('Monthly summary') }
    assert report('monthly', '2026-09-01').payload['rows'].any? { |r| r['metric'].include?('Monthly summary') }
  end

  test 'Square sales and refund dates retain location currency and workspace boundaries' do
    first = order('square-usd', '2026-10-15T15:00:00Z', 1200)
    first.update!(source: 'square', location_id: 'register-a')
    second = order('square-eur', '2026-10-15T16:00:00Z', 900)
    second.update!(source: 'square', location_id: 'register-a', currency: 'EUR')
    old = order('square-old', '2026-10-14T16:00:00Z', 800)
    old.update!(source: 'square', location_id: 'register-b')
    old.refunds.create!(method: 'card', amount_cents: 200, refunded_at: Time.iso8601('2026-10-15T18:00:00Z'))
    old.refunds.create!(method: 'card', amount_cents: 100, refunded_at: Time.iso8601('2026-10-16T18:00:00Z'))
    tenant = Current.tenant
    Current.tenant = Tenant.create!(name: 'Other square', subdomain: 'other-square')
    foreign = order('square-foreign', '2026-10-15T15:00:00Z', 99999)
    foreign.update!(source: 'square')
    Current.tenant = tenant
    rows = report.payload['rows'].select { |row| row['source'] == 'Square' }
    assert_equal 3, rows.size
    assert_equal ['12.0', '9.0'], rows.select { |row| row['metric'] == 'Recorded sales' }.pluck('amount').sort
    assert_equal ['USD', 'EUR'], rows.select { |row| row['metric'] == 'Recorded sales' }.pluck('currency').sort.reverse
    assert_equal '2.0', rows.find { |row| row['metric'] == 'Recorded refunds' }['amount']
    refute report.payload.key?('grand_total')
  end

  test 'Square missing amounts remain unavailable and old sales remain visible in coverage' do
    row = order('square-unknown', '2026-10-15T15:00:00Z', 1000)
    row.update_columns(source: 'square', gross_cents: nil)
    old = order('square-history', '2024-01-01T15:00:00Z', 1000)
    old.update!(source: 'square')
    payload = report.payload
    refute payload['rows'].any? { |item| item['source'] == 'Square' }
    assert payload['warnings'].any? { |warning| warning.include?('Square recorded sales include missing amounts') }
    coverage = payload['source_coverage']
    assert_equal %w[C-Trax Square Shopify SwipeSimple], coverage.pluck('label')
    square = coverage.find { |item| item['key'] == 'square' }
    assert_equal 1, square['period_records']
    assert_equal 2, square['stored_records']
    assert_equal '2024-01-01', square['first_date']
    assert_equal '2026-10-15', square['last_date']
    assert_equal 0, coverage.find { |item| item['key'] == 'swipesimple' }['period_records']
    assert_includes report.csv, 'Records in selected period'
    Current.tenant = Tenant.create!(name: 'Empty coverage', subdomain: 'empty-coverage')
    assert report.payload['source_coverage'].all? { |item| item['stored_records'].zero? }
  end

  test 'API observations override duplicate portal IDs with exact decimal currency amounts' do
    row = { 'transaction_id' => '1', 'status' => 'Settled Successfully', 'transaction_type' => 'Authorization w/ Auto Capture',
      'settled_at' => '2026-10-15T15:00:00Z', 'submitted_at' => '2026-10-14T15:00:00Z', 'currency' => 'USD', 'settlement_cents' => 100 }
    AuthorizeNetPortalExport.create!(gateway_id: '123', kind: 'settled', fingerprint: 'fixture', sha256: 'fixture',
      exported_at: Time.current, original_csv: 'fixture', records_json: [row].to_json)
    AuthorizeNetTransaction.create!(environment: 'production', gateway_id: '123', source_transaction_id: '1',
      transaction_type: 'authCaptureTransaction', payment_status: 'settledSuccessfully', submitted_at: 1.day.ago,
      settled_at: Time.iso8601('2026-10-15T15:00:00Z'), currency: 'USD', authorized_amount: '1.2345', settled_amount: '1.2345', observed_at: Time.current)
    rows = report.payload['rows'].select { |r| r['source'] == 'Authorize.net' }
    assert_equal 1, rows.size
    assert_equal 1, rows.first['count']
    assert_equal '1.2345', rows.first['amount']
    AuthorizeNetTransaction.first.update!(observed_at: 1.day.ago, payment_status: 'capturedPendingSettlement', settled_at: nil)
    latest = report.payload['rows'].find { |r| r['source'] == 'Authorize.net' }
    assert_equal '1.0', latest['amount']
  end

  test 'saved reviews are encrypted replayable tenant scoped and never create business records' do
    order('private', '2026-10-15T15:00:00Z', 8765)
    assert_no_difference ['Core::Order.count', 'Core::Payment.count', 'LedgerEntry.count'] do
      snapshot = report.save!
      assert_equal snapshot.id, report.save!.id
      assert_equal 1, MoneyReconciliation.count
      raw = MoneyReconciliation.connection.select_value("SELECT payload_json FROM money_reconciliations WHERE id = #{snapshot.id}")
      refute_includes raw, '87.65'
      assert snapshot.payload['rows'].any?
    end
    other = Tenant.create!(name: 'Other', subdomain: 'money-other', status: 'active')
    Current.tenant = other
    assert_equal 0, MoneyReconciliation.count
    assert_empty report.payload['rows']
  end

  test 'refresh preserves prior period CSV and JSON evidence and replays unchanged source data' do
    order('original', '2026-10-15T15:00:00Z', 1000)
    report.save!
    originals = ReconciliationDocument.where(kind: 'period_archive').order(:id).to_a
    assert_equal 2, originals.size
    assert_includes originals.find { |doc| doc.filename.end_with?('.json') }.original_bytes, 'Review required'
    report.save!
    assert_equal 2, ReconciliationDocument.where(kind: 'period_archive').count
    order('late-sale', '2026-10-15T17:00:00Z', 500)
    report.save!
    assert_equal 4, ReconciliationDocument.where(kind: 'period_archive').count
    assert_equal 1, MoneyReconciliation.count
    assert_includes originals.find { |doc| doc.filename.end_with?('.csv') }.original_bytes, '10.0'
    assert_equal 4, DailyMoneyReconciliation.new(day: '2026-10-15').documents.size
  end

  test 'CSV quotes untrusted formula text while preserving signed numeric amounts' do
    document = report.payload
    document['rows'] = [{ 'source' => 'SwipeSimple', 'account' => '-SUM(1)', 'currency' => 'USD',
      'metric' => 'Refund', 'count' => 1, 'amount' => '-12.50', 'basis' => 'Observed' }]
    cells = CSV.parse(report.csv(document))[1]
    assert_equal "'-SUM(1)", cells[4]
    assert_equal '-12.50', cells[8]
  end

  test 'missing canonical amounts and malformed cross-tenant refund links do not produce financial totals' do
    own = order('missing-amount', '2026-10-15T15:00:00Z', 1000)
    own.update_columns(gross_cents: nil)
    missing = report.payload
    refute missing['rows'].any? { |row| row['source'] == 'Shopify' && row['metric'] == 'Recorded sales' }
    assert missing['warnings'].any? { |warning| warning.include?('missing amounts') }
    tenant = Current.tenant
    Current.tenant = Tenant.create!(name: 'Foreign refunds', subdomain: 'foreign-refunds')
    foreign = order('foreign', '2026-10-15T15:00:00Z', 90000)
    Current.tenant = tenant
    Core::Refund.new(tenant_id: tenant.id, order_id: foreign.id, method: 'cash', amount_cents: 90000,
      refunded_at: Time.iso8601('2026-10-15T17:00:00Z')).save!(validate: false)
    refute report.payload['rows'].any? { |row| row['metric'] == 'Recorded refunds' }
  end

  test 'scheduled jobs save the previous complete periods without notifications or source writes' do
    BuzzAgent.expects(:notify).never
    %w[daily weekly monthly].each { |kind| MoneyReconciliationJob.perform_now(kind) }
    Current.tenant = tenants(:default_tenant)
    assert_equal 3, MoneyReconciliation.count
    daily = MoneyReconciliation.find_by!(period_kind: 'daily')
    assert_equal Date.new(2026, 10, 14), daily.period_from
    assert_equal Date.new(2026, 10, 14), daily.period_to
    monthly = MoneyReconciliation.find_by!(period_kind: 'monthly')
    assert_equal Date.new(2026, 9, 1), monthly.period_from
    assert_equal Date.new(2026, 9, 30), monthly.period_to
  end

  private

  def report(kind = 'daily', date = '2026-10-15')
    MoneyReconciliationReport.new(kind: kind, date: date)
  end

  def order(id, at, cents)
    row = Core::Order.new(source: 'shopify', source_order_id: id, occurred_at: Time.iso8601(at), gross_cents: cents, currency: 'USD')
    row.mark_paid!
    row.save!
    row
  end

  def iris(from, to, date, amount, kind: 'daily_deposits_csv', observed: Time.current)
    payload = { 'currency' => nil, kind == 'deposits' ? 'deposits' : 'data' => [{ 'date' => date, 'amount' => amount }] }
    IrisReport.create!(api_origin: 'https://fixture.iriscrm.com', merchant_number: '123', report_kind: kind,
      window_from: from, window_to: to, status: 'complete', observed_at: observed, payload_json: payload.to_json)
  end
end
