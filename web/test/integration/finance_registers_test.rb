# frozen_string_literal: true

require 'test_helper'

# Expense and vendor-payment registers: safe exports, locked rows, audit trail.
class FinanceRegistersTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    Finance::ChartOfAccounts.seed!
    @admin = User.find_by!(email: 'admin@example.com')
    post login_path, params: { email: 'admin@example.com', password: 'password' }
  end

  teardown { Current.reset }

  def expense!(attrs = {})
    Finance::Expense.create!({ payee: 'Acme', category: 'supplies', amount_cents: 12_550, incurred_on: Date.current, method: 'card' }.merge(attrs))
  end

  def lock_last_but_one_month
    month = Date.current.beginning_of_month << 2
    post period_locks_path, params: { period_lock: { kind: 'monthly', date: month.iso8601, act: 'lock', confirmed: '1', reason: 'Checked' } }
    month
  end

  test 'csv export neutralises spreadsheet formulas and writes exact decimals' do
    expense!(payee: '=HYPERLINK("http://evil","x")', amount_cents: 123_456_789, notes: '@cmd')
    get finance_expenses_path(format: :csv)
    assert_response :success
    assert_includes response.body, %('=HYPERLINK)
    assert_not_includes response.body, ',=HYPERLINK'
    assert_includes response.body, "'@cmd"
    assert_includes response.body, '1234567.89,USD'
  end

  test 'vendor payment csv neutralises formulas too' do
    vendor = Purchasing::Vendor.create!(name: '+SUM(1)')
    Finance::VendorPayment.create!(vendor: vendor, amount_cents: 500, paid_on: Date.current, method: 'check', reference: '-1')
    get finance_vendor_payments_path(format: :csv)
    assert_includes response.body, "'+SUM(1)"
    assert_includes response.body, "'-1"
    assert_includes response.body, '5.00,USD'
  end

  test 'remove confirmation names the amount, payee, date and what happens next' do
    expense!(payee: 'Utility Co', amount_cents: 12_550, incurred_on: Date.new(2026, 10, 1))
    get finance_expenses_path(from: '2026-10-01', to: '2026-10-31')
    assert_select 'form[data-turbo-confirm]' do |forms|
      text = forms.first['data-turbo-confirm']
      assert_includes text, '$125.50'
      assert_includes text, 'Utility Co'
      assert_includes text, '2026-10-01'
      assert_includes text, 'ledger entry is voided'
      assert_includes text, 'restore'
    end
  end

  test 'a row inside a locked period is read-only with the reason shown' do
    month = Date.current.beginning_of_month << 2
    expense = expense!(payee: 'Old bill', incurred_on: month + 2)
    lock_last_but_one_month
    get finance_expenses_path(from: month.iso8601, to: (month.end_of_month).iso8601)
    assert_select '.status-locked', /Locked/
    assert_select 'td', /Read-only: period locked/
    assert_select "a[href=?]", edit_finance_expense_path(expense), count: 0
    assert_select 'form[action=?]', finance_expense_path(expense), count: 0

    get edit_finance_expense_path(expense)
    assert_select '.entry-state-void', /Read-only/
    assert_select 'fieldset[disabled]'
    assert_select 'input[type=submit]', 0
  end

  test 'removed expenses stay listed as Removed and the filter can hide them' do
    gone = expense!(payee: 'Gone Co')
    delete finance_expense_path(gone)
    get finance_expenses_path
    assert_select 'tr.row-removed .status-removed', 'Removed'
    assert_select 'summary', /Removed .* by /
    get finance_expenses_path(include_deleted: '0')
    assert_select 'tr.row-removed', 0
  end

  test 'history says who recorded an expense' do
    post finance_expenses_path, params: { expense: { payee: 'Tracked', category: 'other', amount: '10.00', incurred_on: Date.current, method: 'cash' } }
    get finance_expenses_path
    assert_select 'details', /Recorded .* by #{Regexp.escape(@admin.display_name)}/m
  end

  test 'payment actions are logged against the payment itself' do
    vendor = Purchasing::Vendor.create!(name: 'Vend')
    post finance_vendor_payments_path, params: { vendor_payment: { vendor_id: vendor.id, amount: '40.00', paid_on: Date.current, method: 'check' } }
    payment = Finance::VendorPayment.last
    delete finance_vendor_payment_path(payment)
    logs = ActivityLog.for_subject('Finance::VendorPayment', payment.id).pluck(:action)
    assert_equal %w[vendor_payment payment_deleted], logs
    get finance_vendor_payments_path
    assert_select 'tr.row-removed .status-removed', 'Removed'
  end

  test 'search and amount filters narrow the list and bad amounts are explained' do
    expense!(payee: 'Alpha Supplies', amount_cents: 1000)
    expense!(payee: 'Beta Rent', amount_cents: 900_000, category: 'rent')
    get finance_expenses_path(q: 'alpha')
    assert_select 'td', text: /Alpha Supplies/
    assert_select 'td', text: /Beta Rent/, count: 0
    get finance_expenses_path(min: '5000.00')
    assert_select 'td', text: /Beta Rent/
    assert_select 'td', text: /Alpha Supplies/, count: 0
    get finance_expenses_path(min: '1,000')
    assert_select '[role=alert]', /amount filter was ignored/
  end

  test 'register tables use banded readable markup with scoped headers and a totals footer' do
    expense!(amount_cents: 123_456_789)
    expense!(amount_cents: 1)
    get finance_expenses_path
    assert_select 'table.finance-table thead th[scope=col]', minimum: 6
    assert_select 'table.finance-table caption.sr-only'
    assert_select 'tfoot .money', text: '$1,234,567.90'
    assert_select 'td.num .money', text: '$1,234,567.89'
  end

  test 'negative and empty states read correctly' do
    get finance_expenses_path
    assert_select '.empty-row', /No expenses match/
    get finance_vendor_payments_path
    assert_select '.empty-row', /No payments match/
  end
end
