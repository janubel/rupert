# frozen_string_literal: true

require 'test_helper'

class ReconciliationFindingsTest < ActiveSupport::TestCase
  setup { Current.tenant = tenants(:default_tenant) }
  teardown { Current.reset }

  test 'only completed tenders clear a positive Square order and other tenants remain private' do
    order = Core::Order.create!(source: 'square', source_order_id: 'fixture-gap', occurred_at: Time.current, gross_cents: 4200, currency: 'USD')
    order.mark_paid!
    payment = order.payments.create!(method: 'card', amount_cents: 4200, paid_at: Time.current, status: 'pending')
    assert_includes Finance::ReconciliationFindings.new.square_missing.pluck(:id), order.id
    payment.update!(status: 'completed')
    refute_includes Finance::ReconciliationFindings.new.square_missing.pluck(:id), order.id
    payment.destroy!
    Current.tenant = Tenant.create!(name: 'Other evidence', subdomain: 'other-evidence')
    assert_empty Finance::ReconciliationFindings.new.square_missing
  end

  test 'latest full invoice snapshots replace old unpaid observations and preserve unknown due dates and leading zeros' do
    import_invoices('unpaid', '2026-10-15T10:00:00Z')
    report = Finance::ReconciliationFindings.new
    assert_equal 1, report.unpaid_invoices.size
    assert_equal '0007', report.unpaid_invoices.first.source_number
    assert_nil report.unpaid_invoices.first.due_on
    assert_equal 2500, report.invoice_groups.first[:cents]
    import_invoices('paid', '2026-10-16T10:00:00Z')
    assert_empty Finance::ReconciliationFindings.new.unpaid_invoices
    assert_equal 2, SwipesimpleReportRow.count
  end

  test 'bank evidence includes account and dates without claiming a match' do
    assert_empty Finance::ReconciliationFindings.new.bank_accounts
    BankStatementLine.create!(account_label: 'Fixture Wells Fargo checking', posted_on: '2026-04-07', amount_cents: 5000,
      description: 'Fixture deposit', fingerprint: 'fixture-bank-line', document_id: 1, line_no: 1)
    assert_equal [['Fixture Wells Fargo checking', 1, '2026-04-07', '2026-04-07']], Finance::ReconciliationFindings.new.bank_accounts.map { |label, count, from, to| [label, count, from.to_s, to.to_s] }
  end

  test 'IRIS controls select whole native monthly snapshots and retain unknown amounts' do
    attrs = { api_origin: 'https://fixture.example', merchant_number: 'fixture', report_kind: 'daily_deposits_csv', status: 'complete',
      window_from: '2026-04-01', window_to: '2026-04-30', observed_at: Time.current, source_digest: 'fixture' }
    report = IrisReport.create!(**attrs, payload_json: { data: [{ amount: '12.34' }], totals: { amount: '12.34' } }.to_json)
    assert_equal({ reports: 1, matched: 1, different: 0, unknown: 0 }, Finance::ReconciliationFindings.new.iris_controls)
    report.update!(payload_json: { data: [{ amount: '12.34' }], totals: { amount: '13.34' } }.to_json)
    assert_equal 1, Finance::ReconciliationFindings.new.iris_controls[:different]
    report.update!(payload_json: { data: [{ amount: nil }], totals: { amount: '13.34' } }.to_json)
    assert_equal 1, Finance::ReconciliationFindings.new.iris_controls[:unknown]
    report.update!(window_to: '2026-04-15')
    assert_equal 0, Finance::ReconciliationFindings.new.iris_controls[:reports]
  end

  private

  def import_invoices(status, at)
    export = SwipesimpleExport.create!(kind: 'invoices', merchant_account: 'Fixture shop', currency: 'USD', source_timezone: 'America/New_York',
      fingerprint: at, sha256: at, exported_at: at, original_csv: 'fixture')
    export.report_rows.create!(identity: 'fixture-invoice', source_row: 2, source_number: '0007', status: status, amount_cents: 2500, occurred_at: '2026-10-14T10:00:00Z')
  end
end
