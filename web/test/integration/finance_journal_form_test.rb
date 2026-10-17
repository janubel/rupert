# frozen_string_literal: true

require 'test_helper'

# Manual journal entry: the server is the authority on what may be posted.
class FinanceJournalFormTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    Finance::ChartOfAccounts.seed!
    @cash = Finance::Account.find_by!(code: '1000')
    @sales = Finance::Account.find_by!(code: '4000')
    post login_path, params: { email: 'admin@example.com', password: 'password' }
  end

  teardown { Current.reset }

  def entry_params(lines, posted_on: Date.current.iso8601, memo: 'Opening float')
    { posted_on: posted_on, memo: memo, lines: lines }
  end

  def line(account, debit: '', credit: '')
    { account_id: account.id, debit: debit, credit: credit, memo: '' }
  end

  test 'an unbalanced entry is rejected, says by how much, and keeps what was typed' do
    assert_no_difference 'Finance::JournalEntry.count' do
      post finance_journal_entries_path, params: entry_params([line(@cash, debit: '100.00'), line(@sales, credit: '99.99')], memo: 'Keep me')
    end
    assert_response :unprocessable_entity
    assert_includes response.body, 'Out of balance by $0.01'
    assert_includes response.body, 'Nothing was posted'
    assert_select 'input[name=memo][value=?]', 'Keep me'
    assert_select 'input[name="lines[][debit]"][value=?]', '100.00'
  end

  test 'a malformed amount is rejected instead of being dropped as zero' do
    assert_no_difference 'Finance::JournalEntry.count' do
      post finance_journal_entries_path, params: entry_params([line(@cash, debit: '1,000.00'), line(@sales, credit: '1000.00')])
    end
    assert_response :unprocessable_entity
    assert_includes response.body, 'Line 1: debit'
    assert_includes response.body, 'is not an amount'
  end

  test 'a line with an amount but no account is rejected, not skipped' do
    rows = [line(@cash, debit: '50.00'), { account_id: '', debit: '', credit: '25.00', memo: '' }, line(@sales, credit: '25.00')]
    assert_no_difference 'Finance::JournalEntry.count' do
      post finance_journal_entries_path, params: entry_params(rows)
    end
    assert_response :unprocessable_entity
    assert_includes response.body, 'Line 2: choose an account.'
  end

  test 'a line cannot carry both a debit and a credit' do
    assert_no_difference 'Finance::JournalEntry.count' do
      post finance_journal_entries_path, params: entry_params([line(@cash, debit: '5.00', credit: '5.00'), line(@sales, credit: '0.01')])
    end
    assert_response :unprocessable_entity
    assert_includes response.body, 'use either Debit or Credit, not both'
  end

  test 'an archived account cannot be posted to' do
    @sales.update!(active: false)
    assert_no_difference 'Finance::JournalEntry.count' do
      post finance_journal_entries_path, params: entry_params([line(@cash, debit: '5.00'), line(@sales, credit: '5.00')])
    end
    assert_response :unprocessable_entity
    assert_includes response.body, 'archived or does not exist'
  end

  test 'an entry dated inside a locked month is blocked with the reason' do
    month = Date.current.beginning_of_month << 2
    post period_locks_path, params: { period_lock: { kind: 'monthly', date: month.iso8601, act: 'lock', confirmed: '1', reason: 'Checked' } }
    assert PeriodLock.locked?(month)
    assert_no_difference 'Finance::JournalEntry.count' do
      post finance_journal_entries_path, params: entry_params([line(@cash, debit: '5.00'), line(@sales, credit: '5.00')], posted_on: (month + 3).iso8601)
    end
    assert_response :unprocessable_entity
    assert_includes response.body, 'is locked'
  end

  test 'a balanced entry posts and records who created it' do
    assert_difference 'Finance::JournalEntry.count', 1 do
      post finance_journal_entries_path, params: entry_params([line(@cash, debit: '1234567.89'), line(@sales, credit: '1234567.89')])
    end
    entry = Finance::JournalEntry.order(:id).last
    assert_redirected_to finance_journal_entry_path(entry)
    assert_equal 123_456_789, entry.debit_cents
    assert entry.created_by_id.present?
  end

  test 'the entry form wires running totals, reasons and a confirmation' do
    get new_finance_journal_entry_path
    assert_response :success
    assert_select 'form[data-controller=journal-form]'
    assert_select '[data-journal-form-target=debitTotal]'
    assert_select '[data-journal-form-target=creditTotal]'
    assert_select '[data-journal-form-target=status][aria-live=polite]'
    assert_select '[data-journal-form-target=reasons][aria-live=polite]'
    assert_select 'form[data-action*="submit->journal-form#confirm"]'
  end

  test 'a hand-keyed entry can be reversed once, by a swapped dated entry' do
    original = Finance::JournalEntry.post!(kind: 'manual', posted_on: Date.current, memo: 'Oops', created_by: User.find_by!(email: 'admin@example.com'),
      lines: [{ account_id: @cash.id, debit_cents: 700 }, { account_id: @sales.id, credit_cents: 700 }])
    assert_difference 'Finance::JournalEntry.count', 1 do
      post reverse_finance_journal_entry_path(original), params: { posted_on: Date.current.iso8601, reason: 'Keyed in error' }
    end
    reversal = Finance::JournalEntry.order(:id).last
    assert_equal 'posted', original.reload.status
    assert_equal [0, 700], reversal.journal_lines.find_by(account_id: @cash.id).then { |l| [l.debit_cents, l.credit_cents] }
    assert_includes reversal.memo, "Reversal of entry ##{original.id}"
    assert_equal 'Finance::JournalEntry', reversal.source_type

    assert_no_difference 'Finance::JournalEntry.count' do
      post reverse_finance_journal_entry_path(original), params: { posted_on: Date.current.iso8601, reason: 'Again' }
    end
    assert_match(/already been reversed/, flash[:alert])
  end

  test 'reversal needs a reason and refuses entries generated from other records' do
    manual = Finance::JournalEntry.post!(kind: 'manual', posted_on: Date.current, created_by: User.find_by!(email: 'admin@example.com'),
      lines: [{ account_id: @cash.id, debit_cents: 100 }, { account_id: @sales.id, credit_cents: 100 }])
    assert_no_difference 'Finance::JournalEntry.count' do
      post reverse_finance_journal_entry_path(manual), params: { posted_on: Date.current.iso8601, reason: ' ' }
    end
    assert_match(/Enter a reason/, flash[:alert])

    generated = Finance::JournalEntry.post!(kind: 'expense', posted_on: Date.current, source_type: 'Finance::Expense', source_id: '99',
      lines: [{ account_id: @cash.id, debit_cents: 100 }, { account_id: @sales.id, credit_cents: 100 }])
    assert_no_difference 'Finance::JournalEntry.count' do
      post reverse_finance_journal_entry_path(generated), params: { posted_on: Date.current.iso8601, reason: 'x' }
    end
    assert_match(/Only hand-keyed entries/, flash[:alert])
  end

  test 'a posted entry reads as read-only, names who posted it, and the reverse confirm names the amount' do
    entry = Finance::JournalEntry.post!(kind: 'manual', posted_on: Date.current, memo: 'Float', created_by: User.find_by!(email: 'admin@example.com'),
      lines: [{ account_id: @cash.id, debit_cents: 123_456_789 }, { account_id: @sales.id, credit_cents: 123_456_789 }])
    get finance_journal_entry_path(entry)
    assert_response :success
    assert_select '.entry-state', /Posted: read-only/
    assert_select 'td.num .money', text: '$1,234,567.89', minimum: 2
    assert_select 'a[href=?]', finance_chart_of_account_path(@cash)
    assert_select 'section[aria-labelledby=entry-history]', /Posted .* by /m
    assert_select 'form[data-controller=confirm-submit]' do |forms|
      assert_includes forms.first['data-confirm-submit-message-value'], '$1,234,567.89'
      assert_includes forms.first['data-confirm-submit-message-value'], 'swapped'
    end
    assert_select '[data-balance=ok]', /Balanced/
  end

  test 'a void entry is labelled void and offers no reverse action' do
    entry = Finance::JournalEntry.post!(kind: 'manual', posted_on: Date.current, created_by: User.find_by!(email: 'admin@example.com'),
      lines: [{ account_id: @cash.id, debit_cents: 100 }, { account_id: @sales.id, credit_cents: 100 }])
    entry.void!
    get finance_journal_entry_path(entry)
    assert_select '.entry-state-void', /Void/
    assert_select 'form[data-controller=confirm-submit]', 0
  end

  test 'the account page lists posted lines with a running balance and totals' do
    Finance::JournalEntry.post!(kind: 'manual', posted_on: Date.current, memo: 'A', created_by: User.find_by!(email: 'admin@example.com'),
      lines: [{ account_id: @cash.id, debit_cents: 1000 }, { account_id: @sales.id, credit_cents: 1000 }])
    get finance_chart_of_account_path(@cash)
    assert_response :success
    assert_select 'h1', /1000 · /
    assert_select 'tfoot .money', text: '$10.00', minimum: 1
    get finance_chart_of_account_path(@cash, from: Date.current + 5)
    assert_select '.empty-row', /No posted lines/
  end
end
