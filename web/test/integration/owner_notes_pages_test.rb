# frozen_string_literal: true

require 'test_helper'

# Pages added from the owner's notes: Thu-Wed pay weeks, daily close summary,
# sales tax report, weekly pay box on the staff page and the new expense categories.
class OwnerNotesPagesTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    @admin = User.find_by!(email: 'admin@example.com')
    post login_path, params: { email: 'admin@example.com', password: 'password' }
  end

  teardown { Current.reset }

  test 'timesheets can show a Thursday to Wednesday week and a custom start' do
    get people_timesheets_path(period: '2026-10-10', wk: 'thu')
    assert_response :success
    assert_select 'time[datetime=?]', '2026-10-08'
    get people_timesheets_path(period: '2026-10-10', wk: 'custom')
    assert_response :success
    assert_select 'time[datetime=?]', '2026-10-10'
    get people_timesheets_path(period: '2026-10-10')
    assert_select 'time[datetime=?]', '2026-10-05'
  end

  test 'daily close pages show the summary section' do
    get daily_reconciliations_path(day: '2026-10-14')
    assert_response :success
    assert_select '#daily-close-summary'
    get financial_close_path(day: '2026-10-14')
    assert_response :success
    assert_select '#daily-close-summary'
  end

  test 'sales tax report takes custom dates and exports CSV' do
    get finance_reports_sales_tax_path(from: '2026-10-01', to: '2026-10-14')
    assert_response :success
    assert_select 'h1', /Sales tax report/
    assert_select '[data-controller=report-table] table'
    get finance_reports_sales_tax_path(from: '2026-10-14', to: '2026-10-01')
    assert_redirected_to finance_reports_sales_tax_path
    get finance_reports_sales_tax_path(format: :csv, from: '2026-10-01', to: '2026-10-14')
    assert_response :success
    assert_includes response.body, 'Sales tax report'
  end

  test 'staff page shows the weekly pay box' do
    employee = People::Employee.create!(first_name: 'Pay', last_name: 'Box')
    People::PayRate.create!(employee: employee, pay_type: 'hourly', hourly_rate_cents: 1850, effective_on: '2026-01-01')
    get people_employee_path(employee, week: '2026-10-10')
    assert_response :success
    assert_select '#pay-week', /Thursday to Wednesday/
    assert_select '#pay-week', /\$18\.50/
  end

  test 'advertising and store are expense choices that post to their own accounts' do
    assert_includes Finance::Expense::CATEGORIES, 'advertising'
    assert_includes Finance::Expense::CATEGORIES, 'store'
    Finance::ChartOfAccounts.seed!
    assert_equal 'Advertising', Finance::Account.find_by!(code: Finance::Posting::EXPENSE_BY_CATEGORY['advertising']).name
    assert_equal 'Store expenses', Finance::Account.find_by!(code: Finance::Posting::EXPENSE_BY_CATEGORY['store']).name
  end
end
