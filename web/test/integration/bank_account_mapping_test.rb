# frozen_string_literal: true

require 'test_helper'

class BankAccountMappingTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    Finance::ChartOfAccounts.seed!
    @cash = Finance::Account.find_by!(code: '1000')
    @checking = Finance::Account.find_by!(code: '1100')
    @expense = Finance::Account.find_by!(code: '6100')
    @user = User.find_by!(email: 'admin@example.com')
    post login_path, params: { email: @user.email, password: 'password' }
  end

  teardown { Current.reset }

  def line(label, cents)
    BankStatementLine.create!(document_id: 1, line_no: 1, account_label: label, posted_on: Date.current,
      description: 'Synthetic bank evidence', amount_cents: cents, fingerprint: SecureRandom.hex(24))
  end

  def entry(account, cents)
    Finance::JournalEntry.post!(kind: 'manual', posted_on: Date.current, memo: 'Synthetic ledger movement',
      lines: [{ account_id: account.id, credit_cents: cents }, { account_id: @expense.id, debit_cents: cents }])
  end

  def reconcile(label)
    Finance::BankReconciliation.new(account_label: label, from: Date.current, to: Date.current)
  end

  test 'unmapped historical labels show unknown difference and cannot be matched' do
    bank_line = line('Legacy', -500)
    ledger = entry(@checking, 500)
    report = reconcile('Legacy')
    assert_nil report.summary[:difference_cents]
    assert_nil report.summary[:gl_net_cents]
    assert_empty report.suggestions
    post finance_bank_reconciliation_match_path, params: { line_id: bank_line.id, journal_entry_id: ledger.id }
    assert_equal 'pending', bank_line.reload.status
    get finance_bank_reconciliation_path(account_label: 'Legacy')
    assert_includes response.body, 'Ledger totals and the difference are unavailable'
  end

  test 'mapping isolates checking from cash and custom bank accounts and excludes ignored lines' do
    bank_line = line('Operating', -500)
    ignored = line('Operating', -100)
    ignored.decide!(status: 'ignored', user: @user)
    cash_entry = entry(@cash, 500)
    checking_entry = entry(@checking, 500)
    custom = Finance::Account.create!(code: '1120', name: 'Second bank', account_type: 'asset')
    entry(custom, 900)
    post finance_bank_reconciliation_account_path, params: { account_label: 'Operating', ledger_account_id: @checking.id }
    assert_redirected_to finance_bank_reconciliation_path(account_label: 'Operating')
    assert_equal @checking.id, BankStatementAccount.find_by!(account_label: 'Operating').ledger_account_id
    report = reconcile('Operating')
    assert_equal checking_entry.id, report.suggestions.fetch(bank_line.id).entry.id
    assert_equal 0, report.summary[:difference_cents]
    assert_equal 1, report.summary[:lines]
    post finance_bank_reconciliation_match_path, params: { line_id: bank_line.id, journal_entry_id: cash_entry.id }
    assert_nil bank_line.reload.journal_entry_id
    assert ActivityLog.where(action: 'bank_statement_account_mapped').exists?
  end

  test 'a transfer can reconcile once per bank account and not twice on the same account' do
    first = line('Cash', 600)
    second = line('Bank', -600)
    BankStatementAccount.create!(account_label: 'Cash', ledger_account: @cash)
    BankStatementAccount.create!(account_label: 'Bank', ledger_account: @checking)
    transfer = Finance::JournalEntry.post!(kind: 'manual', posted_on: Date.current, memo: 'Transfer',
      lines: [{ account_id: @cash.id, debit_cents: 600 }, { account_id: @checking.id, credit_cents: 600 }])
    first.match!(journal_entry: transfer, user: @user)
    second.match!(journal_entry: transfer, user: @user)
    assert_equal 0, reconcile('Bank').summary[:difference_cents]
    duplicate = line('Bank', -600)
    assert_raises(ActiveRecord::RecordInvalid) { duplicate.match!(journal_entry: transfer, user: @user) }
    assert_raises(ActiveRecord::RecordNotUnique) do
      BankStatementLine.transaction(requires_new: true) { duplicate.update_columns(journal_entry_id: transfer.id) }
    end
    assert_empty reconcile('Bank').unmatched_gl
  end

  test 'multiple legs in the selected account form one signed movement' do
    bank_line = line('Bank', -300)
    BankStatementAccount.create!(account_label: 'Bank', ledger_account: @checking)
    split = Finance::JournalEntry.post!(kind: 'manual', posted_on: Date.current, memo: 'Split',
      lines: [{ account_id: @checking.id, credit_cents: 100 }, { account_id: @checking.id, credit_cents: 200 },
              { account_id: @expense.id, debit_cents: 300 }])
    assert_equal 1, reconcile('Bank').gl_movements.size
    bank_line.match!(journal_entry: split, user: @user)
    assert_equal 1, reconcile('Bank').summary[:matched]
  end

  test 'a stale entry object cannot match a journal that has since been voided' do
    bank_line = line('Bank', -500)
    BankStatementAccount.create!(account_label: 'Bank', ledger_account: @checking)
    ledger = entry(@checking, 500)
    stale = Finance::JournalEntry.find(ledger.id)
    ledger.void!
    assert_raises(ActiveRecord::RecordInvalid) { bank_line.match!(journal_entry: stale, user: @user) }
    assert_nil bank_line.reload.journal_entry_id
  end

  test 'existing linked history cannot be remapped or silently reinterpreted' do
    bank_line = line('Historical', -500)
    ledger = entry(@checking, 500)
    bank_line.update_columns(status: 'matched', journal_entry_id: ledger.id)
    wrong = BankStatementAccount.new(account_label: 'Historical', ledger_account: @cash)
    assert_not wrong.save
    mapping = BankStatementAccount.create!(account_label: 'Historical', ledger_account: @checking)
    post finance_bank_reconciliation_account_path, params: { account_label: 'Historical', ledger_account_id: @cash.id }
    assert_equal @checking.id, mapping.reload.ledger_account_id
    assert_equal ledger.id, bank_line.reload.journal_entry_id
  end

  test 'foreign accounts, nonasset accounts, duplicate account aliases and read-only writes are refused' do
    line('Bank', -500)
    other = Tenant.create!(name: 'Other bank tenant', subdomain: 'bank-other')
    foreign_line = BankStatementLine.create!(tenant_id: other.id, document_id: 1, line_no: 2, account_label: 'Bank',
      posted_on: Date.current, description: 'Foreign-only bank evidence', amount_cents: -500, fingerprint: SecureRandom.hex(24))
    foreign = Finance::Account.create!(tenant_id: other.id, code: '1100', name: 'Foreign', account_type: 'asset')
    assert_empty reconcile('Bank').lines.select { |candidate| candidate.id == foreign_line.id }
    get finance_bank_reconciliation_path(account_label: 'Bank')
    assert_response :success
    refute_includes response.body, 'Foreign-only bank evidence'

    post finance_bank_reconciliation_account_path, params: { account_label: 'Bank', ledger_account_id: foreign.id }
    assert_response :not_found
    post finance_bank_reconciliation_account_path, params: { account_label: 'Bank', ledger_account_id: @expense.id }
    assert_response :not_found
    BankStatementAccount.create!(account_label: 'Bank', ledger_account: @checking)
    assert_not BankStatementAccount.new(account_label: 'Alias', ledger_account: @checking).valid?
    @user.update!(role: 'reporting')
    post finance_bank_reconciliation_account_path, params: { account_label: 'Bank', ledger_account_id: @cash.id }
    assert_redirected_to root_path
    assert_equal @checking.id, BankStatementAccount.find_by!(account_label: 'Bank').ledger_account_id
  end

  test 'financial statements and CSVs disclose missing automated sales coverage' do
    [finance_reports_path, finance_reports_trial_balance_path, finance_reports_income_statement_path,
     finance_reports_balance_sheet_path].each do |path|
      get path
      assert_response :success
      assert_includes response.body, 'Incomplete ledger coverage'
    end
    get finance_reports_income_statement_path(format: :csv)
    assert_includes response.body, 'Incomplete ledger coverage'
    assert_equal 0, Finance::JournalEntry.count
  end

  test 'statement decisions cannot silently post a custom bank account withdrawal to checking' do
    file = Rack::Test::UploadedFile.new(StringIO.new("Date,Description,Amount\n#{Date.current.iso8601},Synthetic withdrawal,-5.00\n"),
      'text/csv', original_filename: 'synthetic.csv')
    post bank_statements_path, params: { account_label: 'Cash statement', file: file }
    document = ReconciliationDocument.where(kind: 'bank_statement').last
    bank_line = BankStatementLine.for_document(document.id).sole
    BankStatementAccount.create!(account_label: 'Cash statement', ledger_account: @cash)
    assert_no_difference ['Finance::Expense.count', 'Finance::JournalEntry.count', 'Finance::VendorPayment.count'] do
      post decide_bank_statement_path(document.id), params: { decisions: { bank_line.id => 'expense:shipping' } }
    end
    assert_equal 'pending', bank_line.reload.status
    assert_includes flash[:alert], 'currently posts to Checking'
  end
end
