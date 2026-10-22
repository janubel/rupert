# frozen_string_literal: true

require 'test_helper'

class ZelleReportImporterTest < ActiveSupport::TestCase
  HEADER = "Date,Amount,Direction,Reference ID,Counterparty,Memo\n"

  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    @options = { account_label: 'Business checking 1234', currency: 'USD', exported_at: '2026-10-15T22:00:00-04:00' }
    travel_to Time.iso8601('2026-10-16T03:00:00Z')
  end

  teardown do
    travel_back
    Current.reset
  end

  test 'preview validates the whole file without any writes or private values in the summary' do
    assert_no_difference ['ZelleExport.count', 'ZelleEntry.count', 'Core::Order.count', 'LedgerEntry.count', 'SwipesimpleExport.count', 'SyncRun.count'] do
      prepared = ZelleReportImporter.preview(fixture, @options)
      assert_equal 4, prepared.rows.length
      assert_equal({ rows: 4, currency: 'USD', credit_count: 3, debit_count: 1, credit_cents: 127_850, debit_cents: 1525,
                     first_posted_on: Date.new(2026, 10, 14), last_posted_on: Date.new(2026, 10, 15) }, prepared.summary)
      refute_includes prepared.summary.to_json, 'Fictional'
      refute_includes prepared.summary.to_json, 'ZTEST'
      assert prepared.rows.all? { |row| row[:tender] == 'zelle' && row[:verification] == 'unverified' }
    end
  end

  test 'import keeps the exact original encrypted and encrypts reference counterparty and memo' do
    receipt = import(fixture)
    assert_equal fixture, receipt.reload.original_csv
    assert_equal Digest::SHA256.hexdigest(fixture.b), receipt.sha256
    assert_equal 4, receipt.row_count
    assert_equal [Date.new(2026, 10, 14), Date.new(2026, 10, 15)], [receipt.first_posted_on, receipt.last_posted_on]
    assert_equal 4, receipt.entries.count
    %w[zelle_exports zelle_entries].zip(%w[original_csv bank_reference]).each do |table, column|
      raw = ZelleExport.connection.select_values("SELECT #{column} FROM #{table}").join
      refute_includes raw, 'ZTEST'
      refute_includes raw, 'Fictional'
    end
    raw = ZelleEntry.connection.select_values('SELECT counterparty || memo FROM zelle_entries WHERE counterparty IS NOT NULL').join
    refute_includes raw, 'Fictional'
    refute_includes raw, 'Wholesale'
  end

  test 'replaying an identical file returns the same receipt without new rows' do
    receipt = import(fixture)
    assert_no_difference ['ZelleExport.count', 'ZelleEntry.count'] do
      assert_equal receipt.id, import(fixture).id
    end
  end

  test 'changed file or context cannot use a stale preview fingerprint' do
    prepared = ZelleReportImporter.preview(fixture, @options)
    assert_raises(ZelleReportImporter::Error) do
      ZelleReportImporter.import!(fixture.sub('48.00', '49.00'), @options, expected_fingerprint: prepared.fingerprint)
    end
    assert_raises(ZelleReportImporter::Error) do
      ZelleReportImporter.import!(fixture, @options.merge(account_label: 'Other'), expected_fingerprint: prepared.fingerprint)
    end
    assert_equal 0, ZelleExport.count
  end

  test 'overlapping exports count each bank reference once and the newest observation wins' do
    import(fixture)
    import(fixture.sub('30.00', '35.00'), @options.merge(exported_at: '2026-10-15T23:00:00-04:00'))
    assert_equal 8, ZelleEntry.count
    assert_equal 4, ZelleEntry.latest.count
    assert_equal [3500], ZelleEntry.latest.where(posted_on: Date.new(2026, 10, 15)).pluck(:amount_cents)
    # a late older file cannot revive the replaced value
    import(fixture, @options.merge(exported_at: '2026-10-15T21:00:00-04:00'))
    assert_equal [3500], ZelleEntry.latest.where(posted_on: Date.new(2026, 10, 15)).pluck(:amount_cents)
  end

  test 'conflicting statements at the same export time are rejected atomically' do
    import(fixture)
    assert_no_difference ['ZelleExport.count', 'ZelleEntry.count'] do
      error = assert_raises(ZelleReportImporter::Error) { import(fixture.sub('30.00', '31.00')) }
      assert_match(/Conflicting observations/, error.message)
    end
  end

  test 'same bank reference under a different account label is a different identity' do
    import(fixture)
    import(fixture, @options.merge(account_label: 'Savings 9999'))
    assert_equal 8, ZelleEntry.latest.count
  end

  test 'daily report totals credits and debits separately per account and posting day' do
    import(fixture)
    totals = ZelleDailyReport.new(day: '2026-10-14').totals
    assert_equal 1, totals.length
    row = totals.first
    assert_equal 'zelle', row[:tender]
    assert_equal 'unverified', row[:verification]
    assert_equal [2, 124_850, 1, 1525, 123_325], row.values_at(:credit_count, :credit_cents, :debit_count, :debit_cents, :net_cents)
    assert_empty ZelleDailyReport.new(day: '2026-10-13').totals
    assert_raises(ArgumentError) { ZelleDailyReport.new(day: 'nope') }
  end

  test 'import never touches SwipeSimple, orders, payments or the ledger' do
    assert_no_difference ['SwipesimpleExport.count', 'SwipesimpleReportRow.count', 'Core::Order.count', 'Core::Payment.count', 'LedgerEntry.count'] do
      import(fixture)
    end
  end

  test 'headers are case-insensitive but unknown duplicate or missing columns are rejected' do
    assert_equal 1, ZelleReportImporter.preview("date,AMOUNT,Direction,reference id\n2026-10-14,1.00,Credit,R1\n", @options).rows.length
    [HEADER.sub('Memo', 'Balance'), "Date,Amount,Direction\n", "Date,Amount,Direction,Reference ID,Memo,memo\n"].each do |bad|
      error = assert_raises(ZelleReportImporter::Error) { ZelleReportImporter.preview(bad + "2026-10-14,1.00,credit,R1,x\n", @options) }
      assert_match(/Unsupported CSV headers/, error.message)
    end
  end

  test 'row validation rejects bad amounts directions dates references and duplicates without echoing values' do
    {
      '2026-10-14,-5.00,credit,R1,,' => /nonnegative dollar amount/,
      '2026-10-14,5,credit,R1,,' => /two decimals/,
      '2026-10-14,0.00,credit,R1,,' => /greater than zero/,
      '2026-10-14,99999999999.00,credit,R1,,' => /exceeds the supported limit/,
      '2026-10-14,5.00,refund,R1,,' => /Direction must be credit/,
      '2026-10-14,5.00,credit,,,' => /bank reference ID is required/,
      '14 Oct 2026,5.00,credit,R1,,' => /posting date/,
      '2026-02-30,5.00,credit,R1,,' => /Invalid calendar date/,
      '2026-10-30,5.00,credit,R1,,' => /after the export time/,
      "2026-10-14,5.00,credit,R1,\"a\u0007b\"," => /control characters/
    }.each do |line, pattern|
      error = assert_raises(ZelleReportImporter::Error, line) { ZelleReportImporter.preview(HEADER + line + "\n", @options) }
      assert_match(pattern, error.message)
      assert_match(/\ARow 2:/, error.message)
    end
    error = assert_raises(ZelleReportImporter::Error) do
      ZelleReportImporter.preview(HEADER + "2026-10-14,5.00,credit,R1,,\n2026-10-14,6.00,debit,R1,,\n", @options)
    end
    assert_match(/Duplicate bank reference/, error.message)
    assert_raises(ZelleReportImporter::Error) { ZelleReportImporter.preview(HEADER, @options) }
  end

  test 'one bad row rejects the whole file' do
    assert_no_difference 'ZelleEntry.count' do
      assert_raises(ZelleReportImporter::Error) { import(fixture + "2026-10-15,x,credit,ZTEST-1005,,\n") }
    end
  end

  test 'size and row bounds are enforced' do
    assert_raises(ZelleReportImporter::Error) { ZelleReportImporter.preview('x' * (ZelleReportImporter::MAX_BYTES + 1), @options) }
    rows = Array.new(ZelleReportImporter::MAX_ROWS + 1) { |i| "2026-10-14,1.00,credit,R#{i},," }
    error = assert_raises(ZelleReportImporter::Error) { ZelleReportImporter.preview(HEADER + rows.join("\n") + "\n", @options) }
    assert_match(/10,000-row limit/, error.message)
    assert_raises(ZelleReportImporter::Error) { ZelleReportImporter.preview(HEADER + "2026-10-14,1.00,credit,R1,#{'a' * 5000},\n", @options) }
    assert_raises(ZelleReportImporter::Error) { ZelleReportImporter.preview("Date,Amount\n\xFF\n", @options) }
  end

  test 'context must name a short account, USD and an explicit-offset export time that is not in the future' do
    [@options.merge(account_label: ''), @options.merge(account_label: 'x' * 101), @options.merge(currency: 'CAD'),
     @options.merge(exported_at: '2026-10-15T22:00:00'), @options.merge(exported_at: '2026-10-15T22:00:00-00:00'),
     @options.merge(exported_at: '2026-10-17T22:00:00-04:00'), @options.merge(exported_at: 'yesterday')].each do |options|
      assert_raises(ZelleReportImporter::Error, options.inspect) { ZelleReportImporter.preview(fixture, options) }
    end
  end

  test 'rows are tenant scoped' do
    receipt = import(fixture)
    other = Tenant.create!(name: 'Foreign zelle', subdomain: 'foreign-zelle')
    Current.tenant = other
    assert_equal 0, ZelleExport.count
    assert_equal 0, ZelleEntry.count
    assert_nil ZelleExport.find_by(id: receipt.id)
  end

  private

  def fixture
    File.read(Rails.root.join('test/fixtures/files/zelle_bank.csv'))
  end

  def import(csv, options = @options)
    prepared = ZelleReportImporter.preview(csv, options)
    ZelleReportImporter.import!(csv, options, expected_fingerprint: prepared.fingerprint)
  end
end
