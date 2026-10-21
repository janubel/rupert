# frozen_string_literal: true

require 'test_helper'

# Database and model backstops for the general ledger (issue #167): legs are
# permanent, entries can only be voided, the database rejects orphaned or
# two-sided legs, BooksCheck reports any unbalanced entry and a period lock
# covers the ledger without invalidating locks taken before it did.
class JournalLedgerIntegrityTest < ActiveSupport::TestCase
  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    Finance::ChartOfAccounts.seed!
    @cash = Finance::Account.find_by!(code: '1000')
    @sales = Finance::Account.find_by!(code: '4000')
  end

  teardown { Current.reset }

  def post_entry(cents: 1000, on: Date.current - 40)
    Finance::JournalEntry.post!(kind: 'manual', posted_on: on, memo: 'Integrity test', lines: [
      { account_id: @cash.id, debit_cents: cents }, { account_id: @sales.id, credit_cents: cents }
    ])
  end

  def raw_line(entry_id:, account_id:, debit: 0, credit: 0)
    now = Time.current
    Finance::JournalLine.insert_all!([{ tenant_id: @tenant.id, journal_entry_id: entry_id, account_id: account_id,
      debit_cents: debit, credit_cents: credit, position: 9, created_at: now, updated_at: now }])
  end

  test 'posted legs cannot be edited or deleted' do
    line = post_entry.journal_lines.first
    assert_raises(ActiveRecord::ReadOnlyRecord) { line.update!(debit_cents: 1) }
    assert_raises(ActiveRecord::ReadOnlyRecord) { line.destroy! }
  end

  test 'a posted entry can be voided but not edited or destroyed' do
    entry = post_entry
    assert_raises(ActiveRecord::RecordInvalid) { entry.update!(memo: 'rewritten') }
    assert_raises(ActiveRecord::ReadOnlyRecord) { entry.reload.destroy }
    entry.reload.void!
    assert entry.reload.void?
    assert_raises(ActiveRecord::RecordInvalid) { entry.update!(status: 'posted') }
  end

  test 'database rejects a leg carrying both a debit and a credit' do
    entry = post_entry
    assert_raises(ActiveRecord::StatementInvalid) { raw_line(entry_id: entry.id, account_id: @cash.id, debit: 5, credit: 5) }
  end

  test 'database rejects a leg with no amount' do
    entry = post_entry
    assert_raises(ActiveRecord::StatementInvalid) { raw_line(entry_id: entry.id, account_id: @cash.id) }
  end

  test 'database rejects a leg pointing at a missing entry or account' do
    entry = post_entry
    # Each violation gets its own savepoint so the second foreign-key check is
    # independent of how the database reports the first constraint failure.
    assert_raises(ActiveRecord::InvalidForeignKey) do
      Finance::JournalLine.transaction(requires_new: true) { raw_line(entry_id: entry.id + 10_000, account_id: @cash.id, debit: 5) }
    end
    assert_raises(ActiveRecord::InvalidForeignKey) do
      Finance::JournalLine.transaction(requires_new: true) { raw_line(entry_id: entry.id, account_id: @cash.id + 10_000, debit: 5) }
    end
  end

  test 'amounts beyond 32 bits are stored exactly' do
    big = 5_000_000_000
    entry = post_entry(cents: big)
    assert_equal big, entry.reload.journal_lines.sum(:debit_cents)
  end

  test 'books check flags an entry written out of balance around normal posting' do
    check = -> { BooksCheck.new.checks.find { |c| c.key == 'ledger_balance' } }
    entry = post_entry
    assert check.call.ok?

    raw_line(entry_id: entry.id, account_id: @cash.id, debit: 250)
    result = check.call
    assert_equal :fix, result.status
    assert_equal 1, result.count
    assert_equal 250, result.cents
    assert_equal ["Entry ##{entry.id}", 1250, 1000], result.rows.first
  end

  test 'voided entries do not count against the ledger balance check' do
    entry = post_entry
    raw_line(entry_id: entry.id, account_id: @cash.id, debit: 250)
    entry.void!
    assert(BooksCheck.new.checks.find { |c| c.key == 'ledger_balance' }.ok?)
  end

  test 'period snapshot covers the ledger and changes when an entry is voided' do
    day = Date.current - 40
    entry = post_entry(on: day)
    before = PeriodSnapshot.new(from: day, to: day)
    # Rows are ordered by their text form, so which account comes first depends on the IDs the database assigned.
    expected = [['posted', @cash.id.to_s, '1', '1000', '0'], ['posted', @sales.id.to_s, '1', '0', '1000']].sort_by { |row| row.map(&:to_s) }
    assert_equal expected, before.totals['ledger']

    entry.void!
    after = PeriodSnapshot.new(from: day, to: day)
    refute_equal before.fingerprint, after.fingerprint
    assert_equal ['General ledger'], after.changed_sections(before.totals)
  end

  test 'a lock recorded before the ledger section existed still matches' do
    day = Date.current - 40
    post_entry(on: day)
    legacy = PeriodSnapshot.new(from: day, to: day).totals.except('ledger')
    lock = PeriodLock.new(period_from: day, period_to: day, summary_json: legacy.to_json,
      fingerprint: Digest::SHA256.hexdigest(legacy.to_json))
    assert lock.still_matches?
    assert_empty PeriodSnapshot.new(from: day, to: day).changed_sections(legacy)

    Core::Order.create!(source: 'square', source_order_id: SecureRandom.uuid, gross_cents: 500, tax_cents: 0,
      occurred_at: Time.zone.local(day.year, day.month, day.day, 12))
    refute lock.still_matches?
  end
end
