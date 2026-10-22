# frozen_string_literal: true

require 'test_helper'

class HistoryReconciliationTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
    Finance::ChartOfAccounts.seed!
    @checking = Finance::Account.find_by!(code: '1100')
    @equity = Finance::Account.find_by!(code: '3000')
  end

  teardown { Current.reset }

  def account(code) = Finance::Account.find_by!(code: code)

  def stage_journal
    QuickbooksImport.stage!(bytes: File.binread(Rails.root.join('test/fixtures/files/quickbooks/journal_basic.csv')), kind: 'journal', filename: 'j.csv', actor: nil).batch
  end

  def map(key, code)
    ImportEntityMapping.find_by!(entity_type: 'account', source_key: key).update!(decision: 'map', target_id: account(code).id)
  end

  def native(date, cents, debit: @checking, credit: @equity)
    Finance::JournalEntry.post!(kind: 'manual', posted_on: date, lines: [{ account_id: debit.id, debit_cents: cents }, { account_id: credit.id, credit_cents: cents }])
  end

  test 'says why when there is nothing to compare, and never invents a comparison' do
    assert_match(/No QuickBooks journal/, HistoryReconciliation.new.ledger.message)
    stage_journal
    assert_match(/no entries of its own/, HistoryReconciliation.new.ledger.message)
    native(Date.new(2025, 1, 1), 100)
    assert_match(/no days in common/, HistoryReconciliation.new.ledger.message)
  end

  test 'lists differences for mapped accounts over the days both cover and never adjusts them' do
    stage_journal
    map('checking', '1100')
    native(Date.new(2024, 1, 9), 100_000)
    comparison = HistoryReconciliation.new.ledger
    assert_equal [Date.new(2024, 1, 9), Date.new(2024, 1, 9)], comparison.period
    row = comparison.rows.find { |r| r.account_id == @checking.id }
    assert_equal [120_000, 100_000, 20_000], [row.quickbooks_cents, row.rupert_cents, row.difference_cents]
    assert_includes comparison.unmapped, 'Accounts Receivable (A/R)'
    assert_equal 0, Finance::JournalEntry.where(kind: 'imported').count
  end

  test 'an agreeing account shows a zero difference' do
    stage_journal
    map('checking', '1100')
    native(Date.new(2024, 1, 9), 120_000)
    assert_equal 0, HistoryReconciliation.new.ledger.rows.find { |r| r.account_id == @checking.id }.difference_cents
  end

  test 'imported entries are never counted as Rupert’s own side' do
    batch = stage_journal
    { 'accounts receivable (a/r)' => '1200', 'sales' => '4000', 'checking' => '1100', 'office supplies' => '5700', 'accounts payable (a/p)' => '2000' }.each { |key, code| map(key, code) }
    QuickbooksPosting.approve!(batch, actor: nil, post_through: Date.new(2024, 12, 31))
    native(Date.new(2024, 1, 9), 120_000)
    row = HistoryReconciliation.new.ledger.rows.find { |r| r.account_id == @checking.id }
    assert_equal [120_000, 120_000], [row.quickbooks_cents, row.rupert_cents]
  end

  test 'trial balance comparison uses all posted entries through the as-of date and flags opening balances' do
    QuickbooksImport.stage!(bytes: File.binread(Rails.root.join('test/fixtures/files/quickbooks/trial_balance.csv')), kind: 'trial_balance', filename: 'tb.csv', actor: nil, as_of: '2024-03-31')
    map('checking', '1100')
    native(Date.new(2024, 2, 1), 50_000)
    comparison = HistoryReconciliation.new.trial_balances.first
    row = comparison.rows.find { |r| r.account_id == @checking.id }
    assert_equal [120_000, 50_000, 70_000], [row.quickbooks_cents, row.rupert_cents, row.difference_cents]
    assert_match(/Opening balances/, row.note)
    assert_includes comparison.unmapped, 'Sales'
    native(Date.new(2024, 2, 2), 100, debit: account('5700'), credit: account('2000'))
    ImportEntityMapping.create!(source: 'quickbooks', entity_type: 'account', source_key: 'accounts payable (a/p)', source_name: 'Accounts Payable (A/P)', decision: 'map', target_id: account('2000').id)
    rows = HistoryReconciliation.new.trial_balances.first.rows
    assert_match(/mapped QuickBooks account has no/, rows.find { |r| r.account_id == account('2000').id }.note)
    assert_match(/No QuickBooks account is mapped/, rows.find { |r| r.account_id == account('5700').id }.note)
  end

  test 'bank statement lines are compared month by month with the mapped QuickBooks account' do
    stage_journal
    map('checking', '1100')
    BankStatementAccount.create!(account_label: 'Operating', ledger_account: @checking)
    BankStatementLine.create!(document_id: 1, account_label: 'Operating', line_no: 1, posted_on: Date.new(2024, 1, 9), description: 'Deposit', amount_cents: 119_000, fingerprint: 'a')
    comparison = HistoryReconciliation.new.bank.first
    jan = comparison.rows.find { |r| r.month == '2024-01' }
    assert_equal [120_000, 119_000, 1000], [jan.quickbooks_cents, jan.bank_cents, jan.difference_cents]
  end
end
