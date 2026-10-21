# frozen_string_literal: true

require 'test_helper'

class QuickbooksCsvTest < ActiveSupport::TestCase
  FIXTURES = Rails.root.join('test/fixtures/files/quickbooks')

  def fixture(name) = File.binread(FIXTURES.join(name))
  def parse(bytes, kind: 'journal') = QuickbooksCsv.parse(bytes, kind: kind)

  test 'reads a Journal report with titles, a leading blank column, continuation lines and a total row' do
    result = parse(fixture('journal_basic.csv'))
    assert_equal 6, result.rows.size
    assert_equal ['g:1', 'g:1', 'g:2', 'g:2', 'g:3', 'g:3'], result.rows.map(&:txn_key)
    assert_equal [120_000, 0], [result.rows[0].debit_cents, result.rows[0].credit_cents]
    assert_equal 'Invoice', result.rows[1].txn_type, 'continuation lines inherit the transaction header'
    assert_equal({ 'debit_cents' => 244_550, 'credit_cents' => 244_550 }, result.control)
    assert_includes result.notes.join, 'blank date'
  end

  test 'groups by Trans # when that column exists and reads ISO dates' do
    result = parse(fixture('journal_flat_trans_no.csv'))
    assert_equal %w[t:101 t:101 t:102 t:102], result.rows.map(&:txn_key)
    assert_equal Date.new(2024, 3, 31), result.rows.last.date
  end

  test 'a single signed Amount column is refused rather than guessed' do
    error = assert_raises(QuickbooksCsv::Error) { parse("Date,Transaction Type,Num,Name,Account,Amount\n01/01/2024,Check,1,X,Checking,-5.00\n") }
    assert_includes error.message, 'single Amount column'
  end

  test 'excel workbooks, binary data and decimal-comma exports are refused with a reason' do
    assert_raises(QuickbooksCsv::Error) { parse("PK\x03\x04binary".b) }
    assert_raises(QuickbooksCsv::Error) { parse("Date;Account;Debit;Credit\n01.01.2024;X;1,50;\n") }
    assert_raises(QuickbooksCsv::Error) { parse('') }
  end

  test 'a row with a bad date, amount or both sides is kept as rejected with the reason' do
    csv = "Date,Account,Debit,Credit\n13/45/2024,A,1.00,\n01/02/2024,B,abc,\n01/02/2024,C,1.00,1.00\n01/02/2024,D,1.001,\n01/02/2024,E,-5.00,\n01/02/2024,F,2.00,\n"
    rows = parse(csv).rows
    assert_equal 5, rows.count(&:rejected?)
    assert_match(/real date|Could not read the date/, rows[0].reason)
    assert_match(/read the amount/, rows[1].reason)
    assert_match(/both a debit and a credit/, rows[2].reason)
    assert_match(/more than two decimal/, rows[3].reason)
    assert_match(/negative/, rows[4].reason)
    assert_not rows[5].rejected?
  end

  test 'money is exact: parentheses, dollar signs, thousands separators and trailing zeros' do
    assert_equal 123_456, QuickbooksCsv.cents('1,234.56')
    assert_equal(-500, QuickbooksCsv.cents('(5.00)'))
    assert_equal 29, QuickbooksCsv.cents('$0.29')
    assert_equal 100, QuickbooksCsv.cents('1.0000')
    assert_equal 50, QuickbooksCsv.cents('.50')
    assert_raises(QuickbooksCsv::Error) { QuickbooksCsv.cents('1.234,56') }
    assert_raises(QuickbooksCsv::Error) { QuickbooksCsv.cents('12,50') }
  end

  test 'dates are read month first and ambiguous formats are noted' do
    assert_equal Date.new(2024, 2, 3), QuickbooksCsv.date('02/03/2024')
    assert_equal Date.new(2024, 2, 3), QuickbooksCsv.date('2024-02-03')
    assert_equal Date.new(2024, 2, 3), QuickbooksCsv.date('2/3/24')
    assert_raises(QuickbooksCsv::Error) { QuickbooksCsv.date('25/01/2024') }
    assert_raises(QuickbooksCsv::Error) { QuickbooksCsv.date('01/01/1850') }
  end

  test 'handles a UTF-8 BOM, UTF-16 and Windows-1252 encodings' do
    csv = "Date,Account,Debit,Credit\n01/02/2024,Café,1.00,\n01/02/2024,Bank,,1.00\n"
    assert_equal 'Café', parse("\uFEFF#{csv}".b).rows.first.account
    assert_equal 'Café', parse("\xFF\xFE".b + csv.encode('UTF-16LE').b).rows.first.account
    cp1252 = csv.encode('Windows-1252').b
    result = parse(cp1252)
    assert_equal 'Café', result.rows.first.account
    assert_includes result.notes.join, 'Windows-1252'
  end

  test 'reads chart of accounts, vendors and a trial balance' do
    accounts = parse(fixture('chart_of_accounts.csv'), kind: 'chart_of_accounts').rows
    assert_equal %w[Checking Bank 1000], [accounts[0].account, accounts[0].account_type, accounts[0].account_number]
    assert_equal 'asset', QuickbooksCsv.rupert_type('Accounts receivable (A/R)')
    assert_nil QuickbooksCsv.rupert_type('Weird Type')
    assert_equal ['Vendor One', 'Vendor Two'], parse(fixture('vendors.csv'), kind: 'vendors').rows.map(&:account)
    tb = parse(fixture('trial_balance.csv'), kind: 'trial_balance')
    assert_equal [120_000, 0], [tb.rows[0].debit_cents, tb.rows[0].credit_cents]
    assert_equal 120_000, tb.control['debit_cents']
  end
end
