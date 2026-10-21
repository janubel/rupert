# frozen_string_literal: true

require 'test_helper'

class HistorySummaryTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
    Finance::ChartOfAccounts.seed!
  end

  teardown { Current.reset }

  def bank_line(date, index, amount = -500)
    BankStatementLine.create!(document_id: 1, account_label: 'Operating', line_no: index, posted_on: date, description: "Line #{index}", amount_cents: amount, fingerprint: "fp-#{date}-#{index}")
  end

  def source(key) = HistorySummary.call.find { |row| row.key == key }

  test 'reports earliest, latest, counts, empty months and years for a source, never claiming the business start' do
    bank_line(Date.new(2024, 1, 10), 1)
    bank_line(Date.new(2024, 1, 20), 2)
    bank_line(Date.new(2024, 4, 2), 3)
    bank = source('bank')
    assert_equal [Date.new(2024, 1, 10), Date.new(2024, 4, 2), 3], [bank.first_date, bank.last_date, bank.records]
    assert_equal %w[2024-02 2024-03], bank.gap_months
    assert_equal({ '2024' => 3 }, bank.by_year)
    assert_not_nil bank.last_import_at
    assert_match(/no live bank feed/i, bank.caveat)
  end

  test 'a source with nothing retained says so and has no dates' do
    ctrax = source('ctrax')
    assert_equal [0, nil, nil, 0], [ctrax.records, ctrax.first_date, ctrax.last_date, ctrax.gap_total]
  end

  test 'quickbooks counts staged transactions separately from posted and the ledger excludes imported entries' do
    batch = QuickbooksImport.stage!(bytes: File.binread(Rails.root.join('test/fixtures/files/quickbooks/journal_basic.csv')), kind: 'journal', filename: 'j.csv', actor: nil).batch
    qb = source('quickbooks')
    assert_equal [3, Date.new(2024, 1, 5), Date.new(2024, 2, 1)], [qb.records, qb.first_date, qb.last_date]
    assert_equal({ 'posted_transactions' => 0, 'staged_transactions' => 3, 'journal_entries_posted' => 0, 'batches' => { 'staged' => 1 } }, qb.detail)
    assert_equal 0, source('ledger').records
    Finance::JournalEntry.post!(kind: 'manual', posted_on: Date.new(2024, 3, 1), lines: [
      { account_id: Finance::Account.find_by!(code: '1100').id, debit_cents: 100 }, { account_id: Finance::Account.find_by!(code: '3000').id, credit_cents: 100 }
    ])
    assert_equal 1, source('ledger').records
    assert batch.staged?
  end

  test 'overlapping spans are listed per source and the 365-day order mirror is never offered as history' do
    bank_line(Date.new(2024, 1, 10), 1)
    bank_line(Date.new(2024, 3, 2), 2)
    QuickbooksImport.stage!(bytes: File.binread(Rails.root.join('test/fixtures/files/quickbooks/journal_basic.csv')), kind: 'journal', filename: 'j.csv', actor: nil)
    overlaps = source('quickbooks').overlaps
    assert_equal [{ 'key' => 'bank', 'label' => 'Bank statements', 'from' => '2024-01-10', 'to' => '2024-02-01' }], overlaps
    assert_not_includes source('bank').overlaps.map { |o| o['key'] }, 'order_mirror'
    assert_match(/not an archive|not read this as history/i, source('order_mirror').caveat)
  end

  test 'to_h exposes only dates, counts and labels' do
    bank_line(Date.new(2024, 1, 10), 1, -987_654)
    json = HistorySummary.new.to_h.to_json
    assert_not_includes json, '987654'
    assert_not_includes json, 'Line 1'
  end

  test 'data is scoped to the workspace' do
    bank_line(Date.new(2024, 1, 10), 1)
    Current.tenant = Tenant.create!(id: 'other-tenant', name: 'Other', subdomain: 'other', shopify_shop_domain: 'other.myshopify.com', status: 'active')
    assert_equal 0, source('bank').records
  end
end
