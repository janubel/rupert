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

  test 'a 5,000-row statement is inserted in batches, not one statement per row' do
    rows = (1..5_000).map { |i| "#{(Date.new(2026, 1, 1) + (i % 300)).iso8601},PAYEE #{i},-#{format('%.2f', (i % 500) + 1.25)}" }
    csv = "Date,Description,Amount\n#{rows.join("\n")}\n"
    statements = []
    subscriber = ActiveSupport::Notifications.subscribe('sql.active_record') do |*, payload|
      statements << payload[:sql] unless %w[SCHEMA TRANSACTION].include?(payload[:name])
    end
    result = importer(csv).import!(filename: 'year.csv', actor: nil)
    ActiveSupport::Notifications.unsubscribe(subscriber)
    puts "SQL statements for 5,000 rows: #{statements.size}"
    assert_equal [5_000, 0], [result[:created], result[:duplicates]]
    assert_equal 5_000, BankStatementLine.count
    assert_operator statements.size, :<, 1_000
    line = BankStatementLine.for_document(result[:document].id).find_by!(line_no: 2)
    assert_equal 'PAYEE 1', line.description
    assert_equal(-225, line.amount_cents)
    assert_equal 'pending', line.status
    assert_equal Current.tenant_id, line.tenant_id
  end

  test 'a file with lines inside a locked month is refused up front, naming the period' do
    PeriodLock.record!(action: 'lock', kind: 'monthly', date: Date.new(2026, 3, 1), user: users(:regular_user))
    csv = "Date,Description,Amount\n2026-02-27,OPEN MONTH,-4.00\n2026-03-02,LOCKED,-5.00\n2026-03-09,LOCKED TOO,-6.00\n"
    error = assert_raises(BankStatementImport::Error) { importer(csv).import!(filename: 'q1.csv', actor: nil) }
    assert_includes error.message, '2 line(s) are dated inside locked periods: March 2026'
    assert_equal 0, BankStatementLine.count
    assert_equal 0, ReconciliationDocument.where(kind: 'bank_statement').count
  end

  test 'oversized files say how to split them' do
    long = "Date,Description,Amount\n2025-01-01,A,-1.00\n2026-01-02,B,-1.00\n"
    error = assert_raises(BankStatementImport::Error) { importer(long).import!(filename: 'two-years.csv', actor: nil) }
    assert_includes error.message, 'more than one year. Split it into files covering one year or less'
    many = "Date,Description,Amount\n#{(1..5_001).map { |i| "2026-01-01,ROW #{i},-1.00" }.join("\n")}\n"
    error = assert_raises(BankStatementImport::Error) { importer(many).rows }
    assert_includes error.message, 'This file has 5001 rows; the limit is 5000. Split it into smaller files'
  end

  test 'encrypted columns written in batches read back decrypted' do
    result = importer("Date,Description,Amount\n2026-10-14,\"CAFÉ, SÖHNE\",-4.00\n").import!(filename: 'a.csv', actor: nil)
    line = BankStatementLine.for_document(result[:document].id).first
    assert_equal 'CAFÉ, SÖHNE', line.description
    assert_equal 'CAFÉ, SÖHNE', BankStatementLine.find(line.id).description
    raw = ActiveRecord::Base.connection.select_value('SELECT description FROM bank_statement_lines LIMIT 1')
    assert_not_includes raw, 'SÖHNE'
  end
end
