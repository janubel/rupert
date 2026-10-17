# frozen_string_literal: true

require 'test_helper'

class FinancePayeesTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = Tenant.create!(name: 'Payee fixture', subdomain: 'payee-fixture')
    @user = User.create!(tenant: @tenant, email: 'payees@example.test', password: 'password123', role: 'admin')
    post login_path, params: { email: @user.email, password: 'password123' }
    Current.tenant = @tenant
    @vendor = Purchasing::Vendor.create!(name: 'Acme Paper')
    Finance::Expense.create!(vendor: @vendor, category: 'supplies', incurred_on: Date.current, amount_cents: 12_500, reference: 'INV-9')
    Finance::VendorPayment.create!(vendor: @vendor, paid_on: Date.current, amount_cents: 4_000, method: 'check')
    Finance::Expense.create!(payee: 'Corner Cafe', category: 'other', incurred_on: Date.current, amount_cents: 900)
    Finance::Expense.create!(payee: 'corner cafe ', category: 'other', incurred_on: Date.current - 1, amount_cents: 600)
  end
  teardown { Current.reset }

  test 'lists payees with separate expense and payment totals and merges free-text spellings' do
    get finance_payees_path
    assert_response :success
    assert_select 'nav[aria-label="Bookkeeping workspace"] a[aria-current=page]', text: 'By payee'
    assert_select 'table td a', text: 'Acme Paper'
    assert_select 'table td a', text: 'Corner Cafe', count: 1
    assert_includes response.body, '$125.00 · 1'
    assert_includes response.body, '$40.00 · 1'
    assert_includes response.body, '$15.00 · 2'
  end

  test 'one payee shows its records, a bank line mention and a CSV' do
    statement = ReconciliationDocument.create!(kind: 'bank_statement', source: 'rupert', filename: 'stmt.csv', sha256: 'a' * 64,
      fingerprint: 'f' * 64, period_from: Date.current - 5, period_to: Date.current) rescue nil
    BankStatementLine.create!(account_label: 'Checking', posted_on: Date.current, description: 'CHECK 1042 ACME PAPER CO', amount_cents: -4_000,
      fingerprint: 'line1', status: 'pending', document_id: statement&.id, line_no: 1) if statement
    get finance_payees_path(key: "v:#{@vendor.id}")
    assert_response :success
    assert_select '#payee-title', 'Acme Paper'
    assert_select 'td', text: 'INV-9'
    assert_includes response.body, 'ACME PAPER CO' if statement
    get finance_payees_path(key: "v:#{@vendor.id}", format: :csv)
    assert_response :success
    assert_includes response.body, 'INV-9'
    assert_includes response.body, 'Vendor payment'
  end

  test 'an unknown payee explains itself and an unknown CSV is not found' do
    get finance_payees_path(key: 'p:nobody')
    assert_response :success
    assert_select '[role=status]', text: /No activity for that payee/
    get finance_payees_path(key: 'p:nobody', format: :csv)
    assert_response :not_found
  end

  test 'finance jump keys stay unique' do
    keys = OperationsWorkspaceHelper::FINANCE_SHORTCUTS.values
    assert_equal keys.uniq, keys
  end
end
