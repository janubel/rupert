# frozen_string_literal: true

require 'test_helper'

# An expense and its ledger entry succeed or fail together.
class FinancePostingAtomicTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    post login_path, params: { email: 'admin@example.com', password: 'password' }
  end

  teardown { Current.reset }

  def params_for(payee = 'Atomic Co')
    { expense: { payee: payee, category: 'supplies', amount: '12.50', incurred_on: Date.current, method: 'cash' } }
  end

  test 'a tenant that never opened the chart gets it created and the expense is posted' do
    assert_equal 0, Finance::Account.count
    assert_difference ['Finance::Expense.count', 'Finance::JournalEntry.count'], 1 do
      post finance_expenses_path, params: params_for
    end
    assert_redirected_to finance_expenses_path
    assert Finance::Account.exists?(code: '1000')
    assert_equal 1250, Finance::JournalEntry.last.debit_cents
  end

  test 'any posting failure leaves no expense behind' do
    Finance::ChartOfAccounts.seed!
    Finance::Posting.stub(:expense, ->(*, **) { raise Finance::Posting::Error, 'ledger refused' }) do
      assert_no_difference 'Finance::Expense.count' do
        post finance_expenses_path, params: params_for
      end
    end
    assert_response :unprocessable_entity
    assert_includes response.body, 'ledger refused'
  end

  test 'a failed repost on edit keeps the old amount and the old entry' do
    Finance::ChartOfAccounts.seed!
    post finance_expenses_path, params: params_for
    expense = Finance::Expense.last
    entry = Finance::JournalEntry.last
    Finance::Posting.stub(:expense, ->(*, **) { raise Finance::Posting::Error, 'ledger refused' }) do
      patch finance_expense_path(expense), params: { expense: { amount: '99.00' } }
    end
    assert_response :unprocessable_entity
    assert_equal 1250, expense.reload.amount_cents
    assert_equal 'posted', entry.reload.status
  end

  test 'a failed restore leaves the expense removed' do
    Finance::ChartOfAccounts.seed!
    post finance_expenses_path, params: params_for
    expense = Finance::Expense.last
    delete finance_expense_path(expense)
    assert expense.reload.discarded?
    Finance::Posting.stub(:expense, ->(*, **) { raise Finance::Posting::Error, 'ledger refused' }) do
      post restore_finance_expense_path(expense)
    end
    assert_match(/ledger refused/, flash[:alert])
    assert expense.reload.discarded?
  end

  test 'editing a removed expense is refused and never re-creates its ledger posting' do
    Finance::ChartOfAccounts.seed!
    post finance_expenses_path, params: params_for
    expense = Finance::Expense.last
    delete finance_expense_path(expense)
    assert expense.reload.discarded?
    assert_equal 0, Finance::JournalEntry.posted.where(source_type: 'Finance::Expense', source_id: expense.id).count
    assert_no_difference 'Finance::JournalEntry.posted.count' do
      patch finance_expense_path(expense), params: { expense: { amount: '99.00' } }
    end
    assert_redirected_to finance_expenses_path
    assert_includes flash[:alert], 'Restore'
    assert_equal 0, Finance::JournalEntry.posted.where(source_type: 'Finance::Expense', source_id: expense.id).count
    assert_equal 1250, expense.reload.amount_cents
  end
end
