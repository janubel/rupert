# frozen_string_literal: true

require 'test_helper'

# Reports and ledger list: labelled, balanced, traceable, safe to export.
class FinanceReportsUiTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    Finance::ChartOfAccounts.seed!
    @cash = Finance::Account.find_by!(code: '1000')
    @sales = Finance::Account.find_by!(code: '4000')
    @admin = User.find_by!(email: 'admin@example.com')
    post login_path, params: { email: 'admin@example.com', password: 'password' }
  end

  teardown { Current.reset }

  def post_entry(cents, on: Date.current, memo: 'Entry', cash: @cash, revenue: @sales)
    Finance::JournalEntry.post!(kind: 'manual', posted_on: on, memo: memo, created_by: @admin,
      lines: [{ account_id: cash.id, debit_cents: cents }, { account_id: revenue.id, credit_cents: cents }])
  end

  test 'trial balance labels dates and currency, links accounts, totals and says balanced' do
    post_entry(123_456_789)
    get finance_reports_trial_balance_path
    assert_response :success
    assert_select '.page-header .page-subtitle', /\A\w{3} \d{1,2}.* – .*\d{4} · USD\z/
    assert_select 'th[scope=col]', text: 'Debit'
    assert_select 'tfoot .money', text: '$1,234,567.89', count: 2
    assert_select 'td a[href*=?]', finance_chart_of_account_path(@cash)
    assert_select '[role=status][data-balance=ok]', /Balanced/
  end

  test 'a negative balance shows a real minus sign in red-class markup' do
    cash2 = Finance::Account.create!(code: '1900', name: 'Petty', account_type: 'asset')
    post_entry(1, cash: cash2, revenue: @cash)
    get finance_reports_trial_balance_path
    assert_select '.money-negative', text: "#{FinanceHelper::MINUS}$0.01"
  end

  test 'ledger list reads out-of-balance in words' do
    post_entry(500)
    # A line imbalance can only come from damaged data, so simulate it directly.
    Finance::JournalLine.where(account_id: @sales.id).update_all(credit_cents: 400)
    get finance_journal_entries_path
    assert_select '[role=status][data-balance=bad]', /Out of balance by \$1\.00/
  end

  test 'balance sheet states the accounting equation result' do
    post_entry(5000)
    get finance_reports_balance_sheet_path
    assert_select '[role=status]', /Balanced: assets equal liabilities plus equity/
  end

  test 'ledger lists more than 100 entries across pages and filters by account, memo and amount' do
    105.times { |i| post_entry(100 + i, memo: "Bulk #{i}") }
    other = Finance::Account.find_by!(code: '4100') || @sales
    post_entry(999_999, memo: 'Special', revenue: other)
    get finance_journal_entries_path
    assert_select '.stat-value', text: '106'
    get finance_journal_entries_path(page: 3)
    assert_response :success
    assert_select 'tbody tr', minimum: 1
    get finance_journal_entries_path(q: 'special')
    assert_select 'tbody tr', 1
    get finance_journal_entries_path(min: '5000')
    assert_select 'tbody tr td', text: /Special/
    get finance_journal_entries_path(account_id: other.id)
    assert_select 'tbody tr', 1
    get finance_journal_entries_path(min: '1,0')
    assert_select '[role=alert]', /amount filter was ignored/
  end

  test 'report csv neutralises account names that look like formulas and states balance' do
    Finance::Account.find_by!(code: '4000').update!(name: '=1+1')
    post_entry(250)
    get finance_reports_trial_balance_path(format: :csv)
    assert_includes response.body, "'=1+1"
    assert_includes response.body, 'Status,Balanced'
    assert_includes response.body, '2.50'
  end

  test 'empty reports say what to do next' do
    get finance_reports_trial_balance_path
    assert_select '.empty-row', /Widen the dates/
    get finance_journal_entries_path
    assert_select '.empty-row', /No entries match/
  end

  test 'bank reconciliation confirm names both records and the effect' do
    entry = post_entry(4200, memo: 'Deposit')
    BankStatementAccount.create!(account_label: 'Main', ledger_account: @cash)
    BankStatementLine.create!(document_id: 1, account_label: 'Main', line_no: 1, posted_on: Date.current, description: 'DEPOSIT',
      amount_cents: 4200, fingerprint: 'fp-1')
    get finance_bank_reconciliation_path(account_label: 'Main', from: Date.current - 3, to: Date.current)
    assert_select 'form[data-turbo-confirm]' do |forms|
      text = forms.first['data-turbo-confirm']
      assert_includes text, '$42.00'
      assert_includes text, "Ledger entry ##{entry.id}"
      assert_includes text, 'No amounts change'
    end
  end

  test 'the Money navigation reaches the general ledger, reports and bank reconciliation' do
    get finance_journal_entries_path
    assert_select 'nav[aria-label="Module"] a[href=?]', finance_journal_entries_path
    assert_select '.page-header a[href=?]', finance_reports_path
    assert_select 'nav[aria-label="Module"] a[href=?]', finance_bank_reconciliation_path
    assert_select 'nav[aria-label="Module"] a[aria-current=page]', 'General ledger'
    get ledger_index_path
    assert_select 'h1', 'Imported orders'
    assert_select 'a[href=?]', finance_journal_entries_path, text: 'General ledger'
  end
end
