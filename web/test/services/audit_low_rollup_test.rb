# frozen_string_literal: true

require 'test_helper'

# Regressions for the LOW findings of the 2026-10-19 bookkeeping and
# reconciliation audit (issue #169) not covered by earlier fixes.
class AuditLowRollupTest < ActiveSupport::TestCase
  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
  end

  teardown { Current.reset }

  def importer(csv, flip: false) = BankStatementImport.new(bytes: csv, account_label: 'Operating checking', withdrawals_positive: flip)

  test 'the same file cannot be re-imported with the withdrawals setting flipped' do
    csv = "Date,Memo,Amount\n2026-10-14,CHECK 101,10.00\n"
    importer(csv, flip: true).import!(filename: 'oct.csv', actor: nil)
    error = assert_raises(BankStatementImport::Error) { importer(csv).import!(filename: 'oct.csv', actor: nil) }
    assert_match(/opposite sign/, error.message)
    assert_equal [-1000], BankStatementLine.pluck(:amount_cents)
  end

  test 'a different file whose lines were all imported already retains nothing' do
    importer("Date,Description,Amount\n2026-10-14,COFFEE,-4.00\n").import!(filename: 'a.csv', actor: nil)
    overlap = "Date,Description,Amount\n\n2026-10-14,COFFEE,-4.00\n"
    assert_no_difference -> { ReconciliationDocument.where(kind: 'bank_statement').count } do
      error = assert_raises(BankStatementImport::Error) { importer(overlap).import!(filename: 'b.csv', actor: nil) }
      assert_match(/already imported/, error.message)
    end
  end

  test 'line numbers match the file when it contains blank rows' do
    rows = importer("Date,Description,Amount\n2026-10-14,A,-1.00\n\n2026-10-15,B,-2.00\n").rows
    assert_equal [2, 4], rows.map(&:line_no)
  end

  test 'a line inserted concurrently is counted as already seen, not an error' do
    csv = "Date,Description,Amount\n2026-10-14,COFFEE,-4.00\n"
    importer(csv).import!(filename: 'oct.csv', actor: nil)
    BankStatementLine.stubs(:exists?).returns(false)
    result = importer(csv).import!(filename: 'oct.csv', actor: nil)
    assert_equal [0, 1], [result[:created], result[:duplicates]]
  end

  test 'a saved money reconciliation inside a locked period is not overwritten' do
    month = (Date.current - 70).beginning_of_month
    report = MoneyReconciliationReport.new(kind: 'monthly', date: month).save!
    before = report.reload.generated_at
    PeriodLock.record!(action: 'lock', kind: 'monthly', date: month, user: users(:regular_user))

    assert_raises(MoneyReconciliationReport::Locked) { MoneyReconciliationReport.new(kind: 'monthly', date: month).save! }
    assert_equal before, report.reload.generated_at
    MoneyReconciliationReport.stubs(:previous_period).returns(month)
    assert_nothing_raised { MoneyReconciliationJob.perform_now('monthly') }
    assert_equal before, report.reload.generated_at
  end

  test 'ledger mirror never overwrites a row owned by another workspace' do
    other = Tenant.create!(name: 'Other ledger', subdomain: 'other-ledger')
    LedgerEntry.unscoped.insert_all!([{ id: 'shopify:gid://shopify/Order/1', tenant_id: other.id, source: 'shopify', sourceOrderId: '1',
      occurredAt: Time.current, syncedAt: Time.current, currency: 'USD', grossCents: 100, status: 'PAID', lineItems: 1 }])
    rows = [{ id: 'shopify:gid://shopify/Order/1', source: 'shopify', sourceOrderId: '1', occurredAt: Time.current,
              syncedAt: Time.current, currency: 'USD', grossCents: 999, status: 'PAID', lineItems: 1, orderName: '#1', summary: '' }]

    assert_equal 0, LedgerImporter.upsert!(rows)
    row = LedgerEntry.unscoped.find('shopify:gid://shopify/Order/1')
    assert_equal [other.id, 100], [row.tenant_id, row.grossCents]
  end

  test 'shopify amounts convert to exact cents' do
    assert_equal 1_915, LedgerImporter.decimal_cents('19.15')
    assert_equal 0, LedgerImporter.decimal_cents(nil)
  end

  test 'only platform off-host backups satisfy the backup check' do
    BackupLog.create!(tenant_id: @tenant.id, status: 'success', startedAt: 1.hour.ago)
    check = BooksCheck.new.checks.find { |c| c.key == 'offsite_backup' }
    assert_equal 1, check.count

    Current.set(tenant: nil) { BackupLog.create!(tenant_id: nil, status: 'success', startedAt: 1.hour.ago) }
    assert BooksCheck.new.checks.find { |c| c.key == 'offsite_backup' }.ok?
  end
end
