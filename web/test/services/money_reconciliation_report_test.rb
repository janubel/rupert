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
    assert_raises(ArgumentError) { report('yearly', '2026-10-15') }
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

  test 'CSV quotes untrusted formula text while preserving signed numeric amounts' do
    document = report.payload
    document['rows'] = [{ 'source' => 'SwipeSimple', 'account' => '-SUM(1)', 'currency' => 'USD',
      'metric' => 'Refund', 'count' => 1, 'amount' => '-12.50', 'basis' => 'Observed' }]
    cells = CSV.parse(report.csv(document))[1]
    assert_equal "'-SUM(1)", cells[4]
    assert_equal '-12.50', cells[8]
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
