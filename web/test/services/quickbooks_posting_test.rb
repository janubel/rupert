# frozen_string_literal: true

require 'test_helper'

class QuickbooksPostingTest < ActiveSupport::TestCase
  FIXTURES = Rails.root.join('test/fixtures/files/quickbooks')

  setup do
    Current.tenant = tenants(:default_tenant)
    @user = users(:regular_user)
    Finance::ChartOfAccounts.seed!
    @batch = QuickbooksImport.stage!(bytes: File.binread(FIXTURES.join('journal_basic.csv')), kind: 'journal', filename: 'j.csv', actor: @user).batch
  end

  teardown { Current.reset }

  def map_all!
    targets = { 'accounts receivable (a/r)' => '1200', 'sales' => '4000', 'checking' => '1100', 'office supplies' => '5700', 'accounts payable (a/p)' => '2000' }
    targets.each do |key, code|
      ImportEntityMapping.find_by!(source_key: key).update!(decision: 'map', target_id: Finance::Account.find_by!(code: code).id)
    end
  end

  def approve(through: Date.new(2024, 12, 31), **options) = QuickbooksPosting.approve!(@batch, actor: @user, post_through: through, **options)

  test 'approval is refused until every account has an explicit decision' do
    assert_equal 5, QuickbooksPosting.undecided_accounts(@batch).size
    error = assert_raises(QuickbooksPosting::Error) { approve }
    assert_match(/5 accounts still need a decision/, error.message)
    assert_equal 0, Finance::JournalEntry.count
  end

  test 'posts balanced entries linked back to their source, once, and records who approved' do
    map_all!
    result = approve
    assert_equal 3, result.posted
    entries = Finance::JournalEntry.where(kind: 'imported')
    assert_equal 3, entries.count
    assert entries.all?(&:balanced?)
    txn = @batch.transactions.find_by(doc_number: '1001')
    assert_equal 'posted', txn.status
    entry = txn.journal_entry
    assert_equal %w[ImportTransaction], [entry.source_type]
    assert_equal txn.id.to_s, entry.source_id
    assert_equal Date.new(2024, 1, 5), entry.posted_on
    assert_equal [@user.id, 'approved'], [entry.created_by_id, @batch.reload.status]
    assert_equal 'posted', @batch.lines.first.status

    again = approve
    assert_equal 0, again.posted
    assert_equal 3, Finance::JournalEntry.where(kind: 'imported').count
  end

  test 'transactions after the chosen date stay staged with the reason, and can be posted later' do
    map_all!
    result = approve(through: Date.new(2024, 1, 31))
    assert_equal 2, result.posted
    assert_equal({ 'after the chosen date' => 1 }, result.held)
    held = @batch.transactions.staged.first
    assert_match(/after the chosen last date/, held.reason)
    assert_equal 1, approve.posted
  end

  test 'a locked period is never touched and the transaction waits' do
    map_all!
    PeriodLock.record!(action: 'lock', kind: 'monthly', date: Date.new(2024, 1, 1), user: @user)
    result = approve
    assert_equal 1, result.posted
    assert_equal 2, result.held['in a locked period']
    assert_equal 0, Finance::JournalEntry.where(posted_on: Date.new(2024, 1, 1)..Date.new(2024, 1, 31)).count
  end

  test 'a skipped account holds the transactions that use it' do
    map_all!
    ImportEntityMapping.find_by!(source_key: 'office supplies').update!(decision: 'skip', target_id: nil)
    result = approve
    assert_equal 2, result.posted
    assert_equal 1, result.held['uses a skipped account']
  end

  test 'creating an account on approval needs a valid code and changes nothing if it is invalid' do
    map_all!
    ImportEntityMapping.find_by!(source_key: 'office supplies').update!(decision: 'create', target_id: nil, proposed_code: '1100', proposed_type: 'expense')
    error = assert_raises(QuickbooksPosting::Error) { approve }
    assert_match(/Could not create the account/, error.message)
    assert_equal 0, Finance::JournalEntry.count

    ImportEntityMapping.find_by!(source_key: 'office supplies').update!(proposed_code: '5710')
    assert_equal 3, approve.posted
    assert_equal 'expense', Finance::Account.find_by!(code: '5710').account_type
  end

  test 'a transaction resembling an earlier import is held unless the person allows it' do
    map_all!
    approve
    edited = File.binread(FIXTURES.join('journal_basic.csv')).gsub('Widgets', 'Gadgets')
    @batch = QuickbooksImport.stage!(bytes: edited, kind: 'journal', filename: 'edited.csv', actor: @user).batch
    result = approve
    assert_equal 1, result.held['resembles an earlier import']
    assert_equal 1, approve(allow_resembling: true).posted
  end

  test 'reversal voids every entry of the batch, frees the fingerprints and keeps the evidence' do
    map_all!
    approve
    assert_equal 3, QuickbooksPosting.reverse!(@batch, actor: @user, reason: 'Wrong company file')
    assert_equal 0, Finance::JournalEntry.posted.where(kind: 'imported').count
    assert_equal 3, Finance::JournalEntry.where(status: 'void').count
    @batch.reload
    assert_equal ['reversed', 'Wrong company file'], [@batch.status, @batch.closed_reason]
    assert_equal ['reversed'], @batch.transactions.distinct.pluck(:status)
    assert @batch.source_document.original_bytes.present?
    # The same file can be staged and approved again afterwards.
    again = QuickbooksImport.stage!(bytes: File.binread(FIXTURES.join('journal_basic.csv')), kind: 'journal', filename: 'j.csv', actor: @user)
    assert again.created
  end

  test 'reversal is refused, changing nothing, while any posted entry sits in a locked period' do
    map_all!
    approve
    PeriodLock.record!(action: 'lock', kind: 'monthly', date: Date.new(2024, 2, 1), user: @user)
    error = assert_raises(QuickbooksPosting::Error) { QuickbooksPosting.reverse!(@batch, actor: @user, reason: 'oops') }
    assert_match(/locked/, error.message)
    assert_equal 3, Finance::JournalEntry.posted.where(kind: 'imported').count
    assert_equal 'approved', @batch.reload.status
  end

  test 'a never-approved batch can be discarded but an approved one cannot' do
    QuickbooksPosting.discard!(@batch, actor: @user)
    assert_equal 'discarded', @batch.reload.status
    assert_equal ['discarded'], @batch.lines.distinct.pluck(:status)
    assert_equal 0, Finance::JournalEntry.count

    map_all!
    other = QuickbooksImport.stage!(bytes: File.binread(FIXTURES.join('journal_basic.csv')), kind: 'journal', filename: 'j2.csv', actor: @user).batch
    QuickbooksPosting.approve!(other, actor: @user, post_through: Date.new(2024, 12, 31))
    assert_raises(QuickbooksPosting::Error) { QuickbooksPosting.discard!(other, actor: @user) }
  end

  test 'suggested cutover is the day before the first native ledger entry' do
    assert_nil QuickbooksPosting.suggested_cutover
    Finance::JournalEntry.post!(kind: 'manual', posted_on: Date.new(2024, 2, 15), lines: [
      { account_id: Finance::Account.find_by!(code: '1100').id, debit_cents: 100 }, { account_id: Finance::Account.find_by!(code: '3000').id, credit_cents: 100 }
    ])
    assert_equal Date.new(2024, 2, 14), QuickbooksPosting.suggested_cutover
    assert_equal 1, QuickbooksPosting.native_entries_between(Date.new(2024, 1, 1), Date.new(2024, 3, 1))
  end

  test 'approving a vendor list creates only the vendors the person chose, and refuses a name clash' do
    batch = QuickbooksImport.stage!(bytes: File.binread(FIXTURES.join('vendors.csv')), kind: 'vendors', filename: 'v.csv', actor: @user).batch
    ImportEntityMapping.find_by!(entity_type: 'vendor', source_key: 'vendor one').update!(decision: 'create')
    QuickbooksPosting.approve!(batch, actor: @user)
    assert_equal ['Vendor One'], Purchasing::Vendor.pluck(:name)
    assert_equal 'map', ImportEntityMapping.find_by!(entity_type: 'vendor', source_key: 'vendor one').decision
    assert_nil Purchasing::Vendor.find_by(name: 'Vendor Two')
  end
end
