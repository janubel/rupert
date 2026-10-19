# frozen_string_literal: true

require 'test_helper'

# Regressions for the Medium/Low findings of the 2026-10-19 bookkeeping and
# reconciliation audit (issue #169): M2, M5, M6, M10 and the LOW error paths.
class BookkeepingHardeningTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    Finance::ChartOfAccounts.seed!
    post login_path, params: { email: 'admin@example.com', password: 'password' }
  end

  teardown { Current.reset }

  def account(code) = Finance::Account.find_by!(code: code)

  def exports = ActivityLog.where(tenant_id: @tenant.id, action: 'data_exported')

  def post_entry(lines, on: Date.current - 3)
    Finance::JournalEntry.post!(kind: 'manual', posted_on: on, memo: 'Hardening test', lines: lines)
  end

  # M6
  test 'an account with ledger lines keeps its code, type and balance side' do
    post_entry([{ account_id: account('6100').id, debit_cents: 500 }, { account_id: account('1100').id, credit_cents: 500 }])
    used = account('6100')

    patch finance_chart_of_account_path(used), params: { account: { code: '6199', name: used.name, account_type: 'expense' } }
    assert_response :unprocessable_entity
    assert_equal '6100', used.reload.code

    patch finance_chart_of_account_path(used), params: { account: { name: 'Renamed', account_type: 'expense' } }
    assert_redirected_to finance_chart_of_accounts_path
    assert_equal 'Renamed', used.reload.name
    log = ActivityLog.where(tenant_id: @tenant.id, action: 'account_updated').order(:id).last
    assert_includes log.details, 'Renamed'
  end

  test 'an unused account can still be reclassified' do
    unused = Finance::Account.create!(code: '6990', name: 'Spare', account_type: 'expense')
    unused.update!(account_type: 'liability', normal_balance: 'credit')
    assert_equal 'liability', unused.reload.account_type
  end

  # M5
  test 'ledger and register exports leave an audit trail' do
    assert_difference -> { exports.count }, 3 do
      post finance_ledger_export_path, params: { from: Date.current.beginning_of_month.iso8601, to: Date.current.iso8601 }
      get finance_expenses_path(format: :csv)
      get finance_vendor_payments_path(format: :csv)
    end
    assert(exports.pluck(:details).any? { |d| d.start_with?('General ledger') })
  end

  # M10
  test 'a compound entry keeps its second bank leg visible after the first is matched' do
    entry = post_entry([{ account_id: account('6100').id, debit_cents: 300 },
                        { account_id: account('1000').id, credit_cents: 100 },
                        { account_id: account('1100').id, credit_cents: 200 }])
    file = Rack::Test::UploadedFile.new(StringIO.new("Date,Description,Amount\n#{entry.posted_on.iso8601},SPLIT PAYMENT,-2.00\n"),
      'text/csv', original_filename: 'split.csv')
    post bank_statements_path, params: { account_label: 'Split checking', file: file }
    line = BankStatementLine.find_by!(description: 'SPLIT PAYMENT')
    line.update_columns(status: 'matched', journal_entry_id: entry.id)

    recon = Finance::BankReconciliation.new(account_label: 'Split checking', from: entry.posted_on - 1, to: entry.posted_on + 1)
    assert_equal [-100], recon.unmatched_gl.map { |m| m[:signed_cents] }
  end

  # M2
  def sale_day!
    day = Date.current - 2
    order = Core::Order.new(source: 'square', source_order_id: 'square-m2', order_number: 'm2', channel: 'pos', gross_cents: 1000,
      tax_cents: 0, occurred_at: Time.zone.local(day.year, day.month, day.day, 12), tenant_id: @tenant.id, location_id: 'loc1')
    order.mark_paid!
    order.save!
    day
  end

  def books_check(key) = BooksCheck.new.checks.find { |c| c.key == key }

  test 'a withdrawn register control no longer covers its day' do
    day = sale_day!
    control = ReconciliationEvidence.retain!(bytes: 'Synthetic control', filename: 'control.txt', source: 'square', kind: 'register_control',
      from: day, to: day, metadata: { 'currency' => 'USD', 'cash' => 0 })
    assert books_check('missing_controls').ok?

    ReconciliationEvidence.retain!(bytes: 'Synthetic withdrawal', filename: 'withdrawal.txt', source: 'square', kind: 'register_control',
      from: day, to: day, metadata: control.metadata.merge('withdrawn' => true, 'note' => 'wrong file'), supersedes_id: control.id)
    assert_equal [[day.iso8601]], books_check('missing_controls').rows
  end

  test 'only a current, latest Reviewed sign-off counts as reviewed' do
    day = sale_day!
    user = users(:regular_user)
    DailyReconciliationReview.create!(day: day, report_digest: DailyMoneyReconciliation.new(day: day.iso8601).digest,
      status: 'reviewed', notes: 'Checked.', reviewed_by: user)
    assert books_check('unreviewed_days').ok?

    DailyReconciliationReview.create!(day: day, report_digest: 'stale-digest', status: 'reviewed', notes: 'Older evidence.', reviewed_by: user)
    assert_equal [[day.iso8601]], books_check('unreviewed_days').rows
  end

  # LOW: malformed input returns a message instead of a server error
  test 'approving with a malformed date redirects instead of failing' do
    post book_approvals_path, params: { approval: { kind: 'daily', date: 'not-a-date', status: 'approved', confirmed: '1' } }
    assert_redirected_to book_approvals_path
  end

  test 'a vendor payment decision naming no vendor saves nothing' do
    file = Rack::Test::UploadedFile.new(StringIO.new("Date,Description,Amount\n2026-10-14,ACME,-12.00\n"), 'text/csv', original_filename: 'v.csv')
    post bank_statements_path, params: { account_label: 'Vendor checking', file: file }
    doc = ReconciliationDocument.where(kind: 'bank_statement').last
    line = BankStatementLine.for_document(doc.id).first

    assert_no_difference -> { Finance::VendorPayment.count } do
      post decide_bank_statement_path(doc.id), params: { decisions: { line.id => 'payment:999999999' } }
    end
    assert_redirected_to bank_statement_path(doc.id)
    assert_match(/existing vendor/, flash[:alert])
    assert line.reload.pending?
  end
end
