# frozen_string_literal: true

require 'test_helper'

class IrisDailyDepositsCsvImportTest < ActiveSupport::TestCase
  setup { Current.tenant = tenants(:default_tenant) }
  teardown { Current.reset }

  test 'native report preserves references signed amounts unknown semantics and encrypted replay safe snapshots' do
    assert_no_difference ['Core::Order.unscoped.count', 'AuthorizeNetTransaction.unscoped.count'] do
      report = import
      assert_equal report.id, import.id
      assert_equal 1, IrisReport.count
      assert_equal 'daily_deposits_csv', report.report_kind
      assert_equal [Date.new(2026, 10, 1), Date.new(2026, 10, 31)], [report.window_from, report.window_to]
      assert_equal Digest::SHA256.hexdigest(csv), report.source_digest
      assert_equal '000001', report.payload['data'].first['batch']
      assert_equal '0007', report.payload['data'].first['terminal_number']
      assert_equal '-2.34', report.payload['data'].last['amount']
      assert_nil report.payload['data'].last['terminal_number']
      assert_nil report.payload['currency']
      assert_equal 'export_records_only', report.payload['coverage']
      assert_equal '0', report.payload['data'].last['type']
      assert_equal({ 'amount' => '10.0', 'transactions' => 3, 'records' => 2 }, report.payload['totals'])
      raw = IrisReport.connection.select_value("SELECT payload_json FROM iris_reports WHERE id = #{report.id}")
      refute_includes raw, '000001'
      refute_includes raw, 'native_daily_deposits_csv'
    end
  end

  test 'corrected same-month file replaces only its own merchant origin and tenant snapshot' do
    first = import
    import(merchant: '67890')
    import(origin: 'https://other.iriscrm.com')
    corrected = csv.sub('12.34', '13.34').sub('10.00', '11.00')
    assert_equal first.id, import(text: corrected).id
    assert_equal '11.0', first.reload.payload['totals']['amount']
    assert_equal 3, IrisReport.count
    Current.tenant = Tenant.create!(name: 'Other deposits', subdomain: 'other-deposits', status: 'active')
    assert_equal 0, IrisReport.count
    import
    assert_equal 1, IrisReport.count
  end

  test 'invalid native files preserve previous snapshots atomically' do
    import
    original = IrisReport.first.attributes
    invalid = [csv.sub('Records exported: 2', 'Records exported: 3'), csv.sub('10.00,3,', '99.00,3,'),
      csv.sub('10.00,3,', '10.00,4,'), csv.sub('10/2/2026', '11/2/2026'), csv.sub('10/2/2026', '2/30/2026'),
      csv.sub('Date,Amount', 'Date,Unexpected'), csv.sub('12.34', '12.345'), csv.sub('12.34', '1,23'),
      csv.sub('12.34,1,', '12.34,1.5,'), csv.sub('12.34,1,', '12.34,-1,'), csv.sub('000001', '=SUM(A1)'),
      csv.sub('000001', "private\u0000reference"), csv.sub('000001', 'x' * 101), csv.sub('Daily Deposits', 'Other report'),
      csv.sub('10/1/2026', '2026-10-01'), csv.sub('000001,0007,0', ',0007,0'), csv + "extra,row\n",
      csv.sub('Type', 'Type,Extra'), "\xFF".dup.force_encoding(Encoding::UTF_8), 'x' * (IrisReporting::DailyDepositsCsvImport::MAX_BYTES + 1)]
    invalid.each do |text|
      assert_raises(IrisReporting::Client::Error) { import(text: text) }
      assert_equal original, IrisReport.first.attributes
    end
  end

  test 'duplicate source records invalid context and oversized record counts are rejected' do
    duplicate = "Daily Deposits\nRecords exported: 2\n\n#{IrisReporting::DailyDepositsCsvImport::HEADER.join(',')}\n10/1/2026,1.00,1,001,,0\n10/1/2026,1.00,1,001,,0\nMonthly Total,2.00,2,\n"
    assert_raises(IrisReporting::Client::Error) { import(text: duplicate) }
    [nil, '2026-13', '2026-1', '2025-10'].each { |period| assert_raises(IrisReporting::Client::Error) { import(period: period) } }
    assert_raises(IrisReporting::Client::Error) { import(merchant: '12345,67890') }
    assert_raises(IrisReporting::Client::Error) { import(origin: 'https://evil.invalid') }
    assert_raises(IrisReporting::Client::Error) { import(text: csv.sub('Records exported: 2', 'Records exported: 10001')) }
    assert_equal 0, IrisReport.count
    Current.tenant.update!(status: 'suspended')
    assert_raises(IrisReporting::Client::Error) { import }
  end

  test 'empty native report is explicit zero exported records and supports BOM CRLF' do
    text = "\uFEFFDaily Deposits\r\nRecords exported: 0\r\n\r\n#{IrisReporting::DailyDepositsCsvImport::HEADER.join(',')}\r\nMonthly Total,0.00,0,\r\n"
    report = import(text: text)
    assert_empty report.payload['data']
    assert_equal 0, report.payload['totals']['records']
    assert_equal Digest::SHA256.hexdigest(text), report.source_digest
  end

  test 'proper grouped currency and parenthesized negatives retain exact decimal amounts' do
    assert_equal BigDecimal('1234.56'), IrisReporting::DailyDepositsCsvImport.amount('$1,234.56')
    assert_equal BigDecimal('-1234.56'), IrisReporting::DailyDepositsCsvImport.amount('($1,234.56)')
    %w[NaN Infinity 1,23.00 $1$2.00 1e2 --1.00].each do |value|
      assert_raises(IrisReporting::Client::Error) { IrisReporting::DailyDepositsCsvImport.amount(value) }
    end
  end

  private

  def csv
    "Daily Deposits\nRecords exported: 2\n\n#{IrisReporting::DailyDepositsCsvImport::HEADER.join(',')}\n10/1/2026,12.34,1,000001,0007,0\n10/2/2026,-2.34,2,000002,,0\nMonthly Total,10.00,3,\n"
  end

  def import(**options)
    IrisReporting::DailyDepositsCsvImport.call(**{ text: csv, merchant: '12345', period: '2026-10' }.merge(options))
  end
end
