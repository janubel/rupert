# frozen_string_literal: true

require 'test_helper'

# Plain-language definitions ("?" disclosures) and "How is this calculated?"
# explainers on the Stock and Money pages, plus the catalog data they rely on.
class LearningDefinitionsTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:regular_user)
    post login_path, params: { email: @user.email, password: 'password' }
  end

  test 'every term has a label and a definition of sensible length' do
    assert LearningCatalog::TERMS.any?
    assert LearningCatalog::TERMS.values.all? { |(label, definition)| label.present? && definition.length.between?(40, 600) },
      'every term needs a label and a 40–600 character definition'
    assert_equal LearningCatalog::TERMS.keys, LearningCatalog::TERMS.keys.uniq
  end

  test 'every page guide path maps to an existing guide' do
    missing = PageGuides::PATH_MAP.map(&:last).reject { |key| PageGuides::GUIDES.key?(key) }
    assert_empty missing, "PATH_MAP points at guides that do not exist: #{missing.inspect}"
    PageGuides::GUIDES.each_value do |guide|
      assert guide.summary.present?, "#{guide.key} needs a summary"
      assert guide.sections.any?, "#{guide.key} needs at least one section"
    end
    assert_equal 'period_locks', PageGuides.for_path('/books/locks').key
    assert_equal 'books_check', PageGuides.for_path('/books_check').key
    assert_equal 'books_desk', PageGuides.for_path('/books').key
    assert_equal 'bank_reconciliation', PageGuides.for_path('/finance/bank_reconciliation').key
    assert_equal 'register_summary', PageGuides.for_path('/reports/register_summary').key
    assert_equal 'reconciliation_overview', PageGuides.for_path('/reconciliation_follow_ups/overview').key
  end

  test 'sales report defines its totals and explains the average order value' do
    get sales_reports_path
    assert_response :success
    assert_select 'details.term summary'
    assert_select 'details.term[data-term="average_sale"]'
    assert_select 'details.calculation[data-calculation="sales-aov"]'
    assert_select 'details.calculation[data-calculation="sales-revenue-per-day"]'
  end

  test 'financial report explains net revenue' do
    get financial_reports_path
    assert_response :success
    assert_select 'details.term[data-term="net_revenue"] summary'
    assert_select 'details.calculation[data-calculation="financial-net-revenue"] .calculation-rows dt', text: 'Net revenue'
  end

  test 'trial balance and general ledger explain whether debits equal credits' do
    get finance_reports_trial_balance_path
    assert_response :success
    assert_select 'th details.term[data-term="debit_credit"] summary'
    assert_select 'details.calculation[data-calculation="trial-balance-check"]'

    get finance_journal_entries_path
    assert_response :success
    assert_select 'details.term[data-term="void_entry"]'
    assert_select 'details.calculation[data-calculation="ledger-balance-check"]'
  end

  test 'bank reconciliation explains statement minus ledger' do
    get finance_bank_reconciliation_path
    assert_response :success
    assert_select 'details.term[data-term="bank_difference"] summary'
    assert_select 'details.calculation[data-calculation="bank-difference"] .calculation-rows dt', text: 'Difference'
  end

  test 'operations report explains the sync success rate' do
    get operations_reports_path
    assert_response :success
    assert_select 'details.term[data-term="cash_variance"] summary'
    assert_select 'details.calculation[data-calculation="sync-success-rate"]'
  end

  test 'bookkeeping overview defines its bank figures' do
    get bookkeeping_path
    assert_response :success
    assert_select 'details.term[data-term="net_cash_movement"] summary'
    assert_select 'details.term[data-term="statement_balance"]'
  end

  test 'a calculated cash forecast explains its final closing cash' do
    post cash_forecast_path, params: { intent: 'calculate', forecast: {
      as_of: Date.yesterday.iso8601, currency: 'USD', horizon: '4', opening: '1000.00', basis: 'assumption', notes: 'Test scenario',
      weeks: { '0' => { receipts: '500', payments: '200' }, '1' => { receipts: '0', payments: '0' }, '2' => { receipts: '0', payments: '0' }, '3' => { receipts: '0', payments: '0' } }
    } }
    assert_response :success
    assert_select 'details.term[data-term="closing_cash"] summary'
    assert_select 'details.calculation[data-calculation="forecast-closing-cash"] .calculation-rows dd', text: /1,300/
  end

  test 'a pay run explains net to pay' do
    post people_pay_runs_path, params: { pay_run: { name: 'Definitions run', period_start: '2026-09-07', period_end: '2026-09-20' } }
    follow_redirect!
    assert_response :success
    assert_select 'details.term[data-term="gross_pay"] summary'
    assert_select 'details.calculation[data-calculation="pay-run-net"] .calculation-rows dt', text: 'Net to pay'
  end

  test 'stock and money index pages render with at least one definition and a page guide' do
    [ledger_index_path, register_summary_reports_path, money_reconciliations_path, finance_accounts_path, finance_chart_of_accounts_path,
     finance_expenses_path, finance_vendor_payments_path, finance_ledger_export_path, finance_reports_income_statement_path,
     finance_reports_balance_sheet_path, stock_requests_path, stock_reservations_path, bulk_materials_path, bulk_recipes_path,
     bulk_consumptions_path, purchasing_purchase_orders_path, purchasing_vendors_path, financial_close_path, cash_forecast_path,
     inventory_reports_path, reconciliation_reports_path, books_check_path, book_approvals_path, bank_statements_path,
     business_snapshot_path, period_locks_path, daily_reconciliations_path].each do |path|
      get path
      assert_response :success, "#{path} did not render"
      assert_select 'details.term summary', { minimum: 1 }, "#{path} has no definition"
      assert PageGuides.for_path(path).present?, "#{path} has no page guide"
    end
  end
end
