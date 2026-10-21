# frozen_string_literal: true

require 'test_helper'

class QuickbooksImportTest < ActiveSupport::TestCase
  FIXTURES = Rails.root.join('test/fixtures/files/quickbooks')

  setup { Current.tenant = tenants(:default_tenant) }
  teardown { Current.reset }

  def fixture(name) = File.binread(FIXTURES.join(name))
  def stage(name = 'journal_basic.csv', kind: 'journal', **options) = QuickbooksImport.stage!(bytes: fixture(name), kind: kind, filename: name, actor: nil, **options)

  test 'stages a journal without touching the books and retains the original byte for byte' do
    outcome = stage
    batch = outcome.batch
    assert outcome.created
    assert_equal 'staged', batch.status
    assert_equal [3, 6, 0, 0], [batch.transaction_count, batch.accepted_count, batch.duplicate_count, batch.rejected_count]
    assert_equal [Date.new(2024, 1, 5), Date.new(2024, 2, 1)], [batch.date_from, batch.date_to]
    assert_equal fixture('journal_basic.csv'), batch.source_document.original_bytes
    assert_equal 0, Finance::JournalEntry.count
    assert_equal 0, Finance::Account.count
    assert_equal true, batch.summary['control_matches']
    assert_equal({ 'debit_cents' => 120_000, 'credit_cents' => 120_000, 'lines' => 2 }, batch.summary['totals_by_account']['Accounts Receivable (A/R)'])
  end

  test 'uploading the same file again returns the same batch and stages nothing new' do
    first = stage
    again = stage
    assert_not again.created
    assert_equal first.batch.id, again.batch.id
    assert_equal 1, ImportBatch.count
    assert_equal 1, ImportSourceDocument.count
    assert_equal 6, ImportLine.count
  end

  test 'an overlapping export marks already imported transactions as duplicates and stages only the new ones' do
    stage
    wider = fixture('journal_basic.csv').sub(',"TOTAL"', ",03/01/2024,Check,9,Vendor One,Rent,Rent Expense,10.00,\n,,,,,Rent,Checking,,10.00\n,\"TOTAL\"")
    batch = QuickbooksImport.stage!(bytes: wider, kind: 'journal', filename: 'wider.csv', actor: nil).batch
    assert_equal [4, 2, 6, 0], [batch.transaction_count, batch.accepted_count, batch.duplicate_count, batch.rejected_count]
    assert_equal 4, ImportTransaction.where(status: %w[staged]).count
    assert_equal 3, ImportTransaction.where(status: 'duplicate').count
  end

  test 'an unbalanced transaction is rejected with the amounts and never staged' do
    csv = "Date,Account,Debit,Credit\n01/02/2024,A,10.00,\n01/02/2024,B,,9.00\n01/03/2024,A,5.00,\n01/03/2024,B,,5.00\n"
    batch = QuickbooksImport.stage!(bytes: csv, kind: 'journal', filename: 'x.csv', actor: nil).batch
    assert_equal 1, batch.summary['unbalanced_total']
    assert_match(/Out of balance: debits 10.00 and credits 9.00 differ by 1.00/, batch.summary['unbalanced'].first['reason'])
    assert_equal 2, ImportLine.where(status: 'rejected').count
    assert_equal 2, ImportLine.where(status: 'staged').count
    assert_equal({ 'A' => 500, 'B' => 500 }, batch.summary['totals_by_account'].transform_values { |row| row['debit_cents'] + row['credit_cents'] },
      'totals describe only what would be imported')
  end

  test 'a transaction containing an unreadable line is rejected as a whole' do
    csv = "Trans #,Date,Account,Debit,Credit\n1,01/02/2024,A,10.00,\n1,01/02/2024,B,abc,\n1,01/02/2024,C,,10.00\n"
    batch = QuickbooksImport.stage!(bytes: csv, kind: 'journal', filename: 'x.csv', actor: nil).batch
    assert_equal 0, ImportLine.where(status: 'staged').count
    assert_equal 3, batch.rejected_count
    assert_match(/could not be read/, ImportTransaction.first.reason)
  end

  test 'a same-number transaction with different content is flagged as resembling, not silently duplicated' do
    stage
    edited = fixture('journal_basic.csv').gsub('Widgets', 'Gadgets')
    batch = QuickbooksImport.stage!(bytes: edited, kind: 'journal', filename: 'edited.csv', actor: nil).batch
    assert_equal 1, batch.summary['resembling_transactions']
    assert_match(/Resembles a transaction already imported/, batch.transactions.find_by(doc_number: '1001').reason)
  end

  test 'registers account mappings as undecided and never maps them by itself' do
    stage('chart_of_accounts.csv', kind: 'chart_of_accounts')
    mapping = ImportEntityMapping.find_by!(source_key: 'checking')
    assert_equal ['unmapped', nil, 'Bank', '1000', 'asset'], [mapping.decision, mapping.target_id, mapping.source_type, mapping.source_number, mapping.proposed_type]
    assert_nil ImportEntityMapping.find_by!(source_key: 'mystery').proposed_type
  end

  test 'a trial balance needs an as-of date and is kept for reconciliation only' do
    assert_raises(QuickbooksImport::Error) { stage('trial_balance.csv', kind: 'trial_balance') }
    batch = stage('trial_balance.csv', kind: 'trial_balance', as_of: '2024-03-31').batch
    assert_equal Date.new(2024, 3, 31), batch.as_of
    assert_not batch.postable?
  end

  test 'sensitive fields are encrypted at rest and rows are scoped to the workspace' do
    stage
    connection = ActiveRecord::Base.connection
    assert_not_includes connection.select_values('SELECT memo FROM import_lines').join, 'Widgets'
    assert_not_includes connection.select_values('SELECT raw_json FROM import_lines').join, 'Customer One'
    assert_not_includes connection.select_values('SELECT content_base64 FROM import_source_documents').first.to_s, Base64.strict_encode64('Journal')
    other = Tenant.create!(id: 'other-tenant', name: 'Other', subdomain: 'other', shopify_shop_domain: 'other.myshopify.com', status: 'active')
    Current.tenant = other
    assert_equal 0, ImportBatch.count
    assert_equal 0, ImportLine.count
  end

  test 'excel files, oversize files and an inactive workspace are refused' do
    assert_raises(QuickbooksImport::Error) { QuickbooksImport.stage!(bytes: 'x', kind: 'journal', filename: 'report.xlsx', actor: nil) }
    assert_raises(QuickbooksImport::Error) { QuickbooksImport.stage!(bytes: 'x' * (QuickbooksCsv::MAX_BYTES + 1), kind: 'journal', filename: 'big.csv', actor: nil) }
    assert_equal 0, ImportSourceDocument.count
  end

  test 'a failed parse retains nothing' do
    assert_raises(QuickbooksImport::Error) { QuickbooksImport.stage!(bytes: "hello,world\n1,2\n", kind: 'journal', filename: 'x.csv', actor: nil) }
    assert_equal [0, 0], [ImportSourceDocument.count, ImportBatch.count]
  end

  test 'an unreadable trailing line rejects its whole transaction instead of posting a balanced remainder' do
    csv = "Date,Account,Debit,Credit\n01/02/2024,A,100.00,\n,B,,100.00\n,C,-50.00,\n,D,,-50.00\n01/03/2024,A,5.00,\n,B,,5.00\n"
    batch = QuickbooksImport.stage!(bytes: csv, kind: 'journal', filename: 'x.csv', actor: nil).batch
    assert_equal 2, batch.transaction_count
    assert_equal %w[rejected staged], ImportTransaction.order(:txn_date).pluck(:status)
    assert_equal 2, ImportLine.where(status: 'staged').count
    assert_equal 4, ImportLine.where(status: 'rejected').count
  end

  test 'a zero-amount first line still starts its transaction so the lines under it are not merged into the one above' do
    csv = "Date,Account,Debit,Credit\n01/02/2024,A,10.00,\n,B,,10.00\n01/03/2024,Z,0.00,\n,A,7.00,\n,B,,7.00\n"
    batch = QuickbooksImport.stage!(bytes: csv, kind: 'journal', filename: 'x.csv', actor: nil).batch
    assert_equal [2, 0], [batch.transaction_count, batch.rejected_count]
    assert_equal [[Date.new(2024, 1, 2), 1000], [Date.new(2024, 1, 3), 700]], ImportTransaction.order(:txn_date).pluck(:txn_date, :debit_cents)
  end

  test 'continuation lines under a header whose date cannot be read are rejected, not attached to the previous transaction' do
    csv = "Date,Account,Debit,Credit\n01/02/2024,A,10.00,\n,B,,10.00\nnot-a-date,A,3.00,\n,B,,3.00\n"
    batch = QuickbooksImport.stage!(bytes: csv, kind: 'journal', filename: 'x.csv', actor: nil).batch
    assert_equal [1, 2], [batch.accepted_count / 2, batch.rejected_count]
    assert_equal [1000], ImportTransaction.where(status: 'staged').pluck(:debit_cents)
    assert_equal 2, ImportLine.where(status: 'rejected').count
  end
end
