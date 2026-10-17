# frozen_string_literal: true

require 'test_helper'

class BookkeepingIntegrationTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    @result = BankStatementImport.new(bytes: "Date,Description,Amount\n2026-04-02,Processor payout,500.00\n2026-04-03,Confirmed software,-25.00\n2026-04-04,Unknown purchase,-45.00\n", account_label: 'Operating').import!(filename: 'april.csv', actor: nil)
    @lines = BankStatementLine.for_document(@result[:document].id).to_a
    @lines.last.update!(review_flag: true, review_category: 'needs_review', review_note: 'What was purchased?')
    post login_path, params: { email: 'admin@example.com', password: 'password' }
  end
  teardown { Current.reset }

  test 'overview defaults to the latest bank month and distinguishes cash from expenses' do
    get bookkeeping_path
    assert_response :success
    assert_select 'h1', 'Bookkeeping'
    assert_includes response.body, 'April 2026'
    assert_includes response.body, 'Currency unverified'
    assert_includes response.body, 'What was purchased?'
    assert_includes response.body, 'No expenses recorded for this month'
    assert_select 'nav[aria-label="Bookkeeping workspace"] a[aria-current=page]', text: 'Overview'
    assert_select "a[href=?]", bank_statement_path(@result[:document].id, anchor: "bank-line-#{@lines.last.id}")
  end

  test 'flagged lines have notes and a working dedicated filter' do
    get bank_statement_path(@result[:document].id, show: 'flagged')
    assert_response :success
    assert_includes response.body, 'What was purchased?'
    assert_select "tr#bank-line-#{@lines.last.id}.bank-flagged"
    assert_select "tr#bank-line-#{@lines.first.id}", count: 0
    post decide_bank_statement_path(@result[:document].id), params: { decisions: { @lines.last.id => 'expense:supplies' } }
    assert_equal 'supplies', @lines.last.reload.review_category
    assert_not @lines.last.review_flag?
    assert @lines.last.reviewed_at
    assert_equal 'recorded', @lines.last.status
  end

  test 'invalid month and unknown account return a useful validation error' do
    get bookkeeping_path(month: '2026-13')
    assert_redirected_to bookkeeping_path
    get bookkeeping_path(account: 'Another workspace account')
    assert_redirected_to bookkeeping_path
  end

  test 'read without finance permission is denied' do
    users(:regular_user).update!(role: 'reporting')
    get bookkeeping_path
    assert_redirected_to root_path
  end

  test 'month drilldown and export include historical records rather than the recent default' do
    Current.tenant = @tenant
    Finance::Expense.create!(payee: 'Historical subscription', category: 'software', amount_cents: 2500, incurred_on: '2026-04-03')
    Finance::Expense.create!(payee: 'Outside selected month', category: 'software', amount_cents: 9000, incurred_on: '2026-03-03')
    get bookkeeping_path(month: '2026-04')
    assert_select 'a[href=?]', finance_expenses_path(month: '2026-04'), minimum: 1
    get finance_expenses_path(month: '2026-04')
    assert_response :success
    assert_includes response.body, 'Historical subscription'
    assert_not_includes response.body, 'Outside selected month'
    get finance_expenses_path(month: '2026-04', format: :csv)
    assert_includes response.body, 'Historical subscription'
    assert_not_includes response.body, 'Outside selected month'
    assert_includes response.headers['Content-Disposition'], 'expenses-2026-04.csv'
    get finance_vendor_payments_path(month: '2026-04')
    assert_response :success
    assert_includes response.body, 'April 2026'
  end

  test 'failed expense posting never leaves a saved expense without its journal' do
    Finance::Posting.stubs(:expense).raises(ActiveRecord::RecordNotFound)
    assert_no_difference ['Finance::Expense.count', 'Finance::JournalEntry.count'] do
      post finance_expenses_path, params: { expense: { payee: 'Posting failure', category: 'software', amount: '25.00', incurred_on: '2026-04-03', method: 'bank_transfer' } }
    end
    assert_response :unprocessable_entity
    assert_includes response.body, 'The expense could not be posted'
    assert_select 'input[name="expense[payee]"][value="Posting failure"]'
  end
end
