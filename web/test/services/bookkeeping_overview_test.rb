# frozen_string_literal: true

require 'test_helper'

class BookkeepingOverviewTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
    @result = BankStatementImport.new(bytes: "Date,Description,Amount\n2026-04-02,Processor payout,500.00\n2026-04-03,Software,-25.00\n", account_label: 'Operating').import!(filename: 'april.csv', actor: nil)
  end
  teardown { Current.reset }

  test 'accounts periods and currencies stay separate and missing balance is not zero' do
    BankStatementImport.new(bytes: "Date,Description,Amount\n2026-04-02,Other account,10000.00\n", account_label: 'Savings').import!(filename: 'savings.csv', actor: nil)
    overview = BookkeepingOverview.new(month: '2026-04', account: 'Operating')
    assert_equal 50_000, overview.credits_cents
    assert_equal 2500, overview.debits_cents
    assert_equal 47_500, overview.net_cents
    assert_equal 2, overview.pending_count
    assert_nil overview.currency
    assert_nil overview.statement_balance
    assert_equal 0, overview.expense_cents
    assert_equal 0, BookkeepingOverview.new(month: '2026-05', account: 'Operating').line_count
  end

  test 'only linked original establishes verified statement balance and currency' do
    ReconciliationEvidence.retain!(bytes: '%PDF-retained-test', filename: 'original.pdf', source: 'bank', kind: 'bank_statement', from: '2026-04-01', to: '2026-04-30', metadata: { currency: 'USD', closing_balance_cents: 123_456, derived_transaction_document_id: @result[:document].id })
    overview = BookkeepingOverview.new(month: '2026-04', account: 'Operating')
    assert_equal 'USD', overview.currency
    assert_equal 123_456, overview.statement_balance[:cents]
    assert_equal Date.new(2026, 4, 30), overview.statement_balance[:date]
    @result[:document].metadata # Original remains immutable.
    Finance::Expense.create!(payee: 'Software', category: 'software', amount_cents: 2500, incurred_on: '2026-04-03')
    assert_equal [['software', 2500]], overview.expense_categories
    assert_equal 2500, overview.expense_cents
    assert_equal 47_500, overview.net_cents
  end

  test 'another tenant sees neither bank activity nor review notes' do
    other = Tenant.create!(id: 'other-bookkeeping', name: 'Other', subdomain: 'other-books', status: 'active')
    Current.tenant = other
    overview = BookkeepingOverview.new(month: '2026-04')
    assert_empty overview.accounts
    assert_equal 0, overview.line_count
    assert_equal 0, overview.expense_cents
    assert_empty overview.questions
    assert_raises(BookkeepingOverview::Error) { BookkeepingOverview.new(account: 'Operating') }
  end
end
