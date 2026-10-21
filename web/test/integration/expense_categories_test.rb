# frozen_string_literal: true

require 'test_helper'

class ExpenseCategoriesTest < ActionDispatch::IntegrationTest
  CSV_TEXT = "Date,Description,Amount\n2026-10-14,PIRATE SHIP LABELS,-42.10\n2026-10-14,ZELLE FROM J SMITH,500.00\n2026-10-15,COFFEE ROASTERS,-18.00\n"

  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    Finance::ChartOfAccounts.seed!
    post login_path, params: { email: 'admin@example.com', password: 'password' }
  end

  teardown { Current.reset }

  def upload
    file = Rack::Test::UploadedFile.new(StringIO.new(CSV_TEXT), 'text/csv', original_filename: 'oct.csv')
    post bank_statements_path, params: { account_label: 'Operating checking', file: file }
    BankStatementAccount.find_or_create_by!(account_label: 'Operating checking') { |m| m.ledger_account = Finance::Account.find_by!(code: '1100') }
    ReconciliationDocument.where(kind: 'bank_statement').last
  end

  test 'categories can be added, renamed, remapped and used to categorize bank lines' do
    get finance_expense_categories_path
    assert_response :success
    assert_select 'td', /Shipping/
    assert_equal Finance::Expense::CATEGORIES.size, Finance::ExpenseCategory.count

    supplies = Finance::Account.find_by!(code: '5700')
    post finance_expense_categories_path, params: { expense_category: { name: 'Coffee & breakroom', ledger_account_id: supplies.id, keywords: 'coffee, roasters' } }
    assert_redirected_to finance_expense_categories_path
    coffee = Finance::ExpenseCategory.find_by!(name: 'Coffee & breakroom')
    assert_equal 'coffee_breakroom', coffee.key

    shipping = Finance::ExpenseCategory.find_by!(key: 'shipping')
    patch finance_expense_category_path(shipping), params: { expense_category: { name: 'Postage & shipping', key: 'hacked' } }
    assert_equal ['shipping', 'Postage & shipping'], shipping.reload.values_at(:key, :name)

    doc = upload
    get bank_statement_path(doc.id)
    assert_includes response.body, 'Suggestion: Coffee &amp; breakroom'
    assert_includes response.body, 'Suggestion: Postage &amp; shipping'
    assert_select 'option[value="expense:coffee_breakroom"]'

    labels, _deposit, coffee_line = BankStatementLine.for_document(doc.id).to_a
    post decide_bank_statement_path(doc.id), params: { decisions: { coffee_line.id => 'expense:coffee_breakroom', labels.id => 'expense:shipping' } }
    expense = Finance::Expense.find(coffee_line.reload.expense_id)
    assert_equal 'coffee_breakroom', expense.category
    debit = Finance::JournalEntry.for_source('Finance::Expense', expense.id).posted.first!.journal_lines.find { |l| l.debit_cents.to_i.positive? }
    assert_equal supplies.id, debit.account_id, 'posts to the mapped ledger account'

    # Recategorize a recorded line through the expense editor, coming back to the statement.
    get bank_statement_path(doc.id, show: 'all')
    assert_select "a[href*='#{edit_finance_expense_path(expense)}']", 'Change'
    patch finance_expense_path(expense), params: { return_to: bank_statement_path(doc.id), expense: { category: 'shipping' } }
    assert_redirected_to bank_statement_path(doc.id)
    assert_equal 'shipping', expense.reload.category
    patch finance_expense_path(expense), params: { return_to: '//evil.example', expense: { category: 'supplies' } }
    assert_redirected_to finance_expenses_path

    patch finance_expense_category_path(coffee), params: { expense_category: { active: '0' } }
    assert_not Finance::ExpenseCategory.active_keys.include?('coffee_breakroom')
    assert_not Finance::Expense.new(category: 'coffee_breakroom', amount_cents: 100, incurred_on: Date.current).valid?
  end

  test 'deposits can be accepted together and named, and are never expenses' do
    doc = upload
    _labels, deposit, coffee_line = BankStatementLine.for_document(doc.id).to_a
    get bank_statement_path(doc.id)
    assert_select 'button', 'Accept all deposits'
    assert_select "input[name='payers[#{deposit.id}]']"
    assert_select "input[name='payers[#{coffee_line.id}]']", 0

    assert_no_difference ['Finance::Expense.count', 'Finance::JournalEntry.count'] do
      post decide_bank_statement_path(doc.id), params: { decisions: { deposit.id => 'deposit' }, payers: { deposit.id => '  J. Smith  (catering) ' } }
    end
    deposit.reload
    assert_equal ['ignored', 'deposit_received', false, 'J. Smith (catering)'], [deposit.status, deposit.review_category, deposit.review_flag, deposit.counterparty]
    assert_equal 'Deposit received', deposit.review_category_label

    post decide_bank_statement_path(doc.id), params: { payers: { deposit.id => 'Jane Smith' } }
    assert_equal 'Jane Smith', deposit.reload.counterparty, 'name can be changed after the decision'

    post decide_bank_statement_path(doc.id), params: { decisions: { coffee_line.id => 'deposit' } }
    assert_match(/not a deposit/, flash[:alert])
    assert coffee_line.reload.pending?
  end
end
