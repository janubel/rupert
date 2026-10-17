# frozen_string_literal: true

require 'test_helper'

class BankStatementImportTest < ActiveSupport::TestCase
  setup { Current.tenant = tenants(:default_tenant) }
  teardown { Current.reset }

  def importer(csv, label: 'Operating checking', flip: false) = BankStatementImport.new(bytes: csv, account_label: label, withdrawals_positive: flip)

  test 'reads a signed amount column with currency symbols and parentheses' do
    rows = importer("Date,Description,Amount\n10/14/2026,UPS STORE,-$42.10\n2026-10-15,DEPOSIT,\"1,200.00\"\n10/16/26,REFUND,(5.00)\n").rows
    assert_equal [-4210, 120_000, -500], rows.map(&:amount_cents)
    assert_equal Date.new(2026, 10, 14), rows.first.posted_on
  end

  test 'reads separate debit and credit columns and skips a preamble' do
    csv = "Account Summary,,,\nStatement for X,,,\nPosting Date,Details,Debit,Credit\n2026-10-14,RENT,1500.00,\n2026-10-15,SALES,,300.00\n"
    assert_equal [-150_000, 30_000], importer(csv).rows.map(&:amount_cents)
  end

  test 'withdrawals-positive banks can be flipped by the person' do
    assert_equal [-1000], importer("Date,Memo,Amount\n2026-10-14,CHECK 101,10.00\n", flip: true).rows.map(&:amount_cents)
  end

  test 'unreadable files are rejected with a reason rather than guessed' do
    assert_raises(BankStatementImport::Error) { importer("Date,Description,Amount\nnot-a-date,X,1.00\n").rows }
    assert_raises(BankStatementImport::Error) { importer("Date,Description,Amount\n2026-10-14,X,abc\n").rows }
    assert_raises(BankStatementImport::Error) { importer("hello,world\n1,2\n").rows }
  end

  test 'account label must be a name, not a number' do
    assert_raises(BankStatementImport::Error) { importer("Date,Description,Amount\n", label: '123456789') }
    assert_raises(BankStatementImport::Error) { importer("Date,Description,Amount\n", label: ' ') }
  end

  test 'import retains the original and never imports a line twice, even identical same-day lines' do
    csv = "Date,Description,Amount\n2026-10-14,COFFEE,-4.00\n2026-10-14,COFFEE,-4.00\n"
    first = importer(csv).import!(filename: 'oct.csv', actor: nil)
    assert_equal [2, 0], [first[:created], first[:duplicates]]
    assert_equal csv, first[:document].original_bytes
    again = importer(csv).import!(filename: 'oct.csv', actor: nil)
    assert_equal [0, 2], [again[:created], again[:duplicates]]
    assert_equal 2, BankStatementLine.count
  end

  test 'descriptions are encrypted at rest' do
    importer("Date,Description,Amount\n2026-10-14,SECRET PAYEE,-4.00\n").import!(filename: 'a.csv', actor: nil)
    raw = ActiveRecord::Base.connection.select_value('SELECT description FROM bank_statement_lines LIMIT 1')
    assert_not_includes raw, 'SECRET PAYEE'
  end
end
