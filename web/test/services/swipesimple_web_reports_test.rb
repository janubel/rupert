# frozen_string_literal: true

require 'test_helper'
require_relative '../support/swipesimple_web_stubs'

# SwipeSimple Reporting (tax/sales CSV) and items.xlsx pulls. All data is synthetic.
class SwipesimpleWebReportsTest < ActiveSupport::TestCase
  include SwipesimpleWebStubs

  TAX_CSV = <<~CSV
    Date,Tax Rate,Pre-Tax Subtotal,Total $ of Sales Tax,Total $ of Sales
    04/01/2026,PA Tax Rate (6.0%),"$1,000.00",$60.00,"$1,060.00"
    04/01/2026,No Tax,$50.00,$0.00,$50.00
    04/02/2026,PA Tax Rate (6.0%),($10.00),-$0.60,$-10.60
    Totals,,"$1,040.00",$59.40,"$1,099.40"
  CSV
  SALES_CSV = <<~CSV
    Date,Subtotals,Discounts,Sales Taxes,Tips,Refunds,Total Net Sales,Total Net Card,Total Net Cash
    04/01/2026,$100.00,,$6.00,$1.00,$0.00,$107.00,$80.00,$27.00
    04/03/2026,$50.00,,$3.00,$0.00,($5.00),$48.00,$48.00,$0.00
    Totals,$150.00,,$9.00,$1.00,($5.00),$155.00,$128.00,$27.00
  CSV
  APRIL = [Date.new(2026, 4, 1), Date.new(2026, 4, 30)].freeze

  setup do
    Current.tenant = tenants(:default_tenant)
    travel_to Time.iso8601('2026-10-16T03:00:00Z')
    @connection = PosConnection.create!(provider: 'swipesimple', environment: 'production', account_reference: '42',
      vendor_approved: true, reporting_enabled: true, credentials_json: { 'web_email' => 'reader@example.invalid', 'web_password' => 'private-login' }.to_json)
    stub_login
  end

  teardown do
    travel_back
    Current.reset
  end

  def parse(text, topic: 'tax', from: APRIL.first, to: APRIL.last)
    SwipesimpleWeb::ReportCsv.parse(text, topic: topic, from: from, to: to)
  end

  def client
    SwipesimpleWeb::Client.new(@connection.credential_values, company_id: '42')
  end

  def account_export!
    bytes = "Transaction #,Date\n"
    SwipesimpleExport.create!(merchant_account: 'Example Wholesale', currency: 'USD', source_timezone: 'America/New_York', kind: 'transactions',
      fingerprint: SecureRandom.hex, sha256: Digest::SHA256.hexdigest(bytes), exported_at: Time.current, original_csv: bytes)
  end

  test 'parses the tax report with money formats, rate labels and a passing Totals check' do
    rows = parse(TAX_CSV)
    assert_equal 3, rows.size
    first, untaxed, refund = rows
    assert_equal [Date.new(2026, 4, 1), 'PA Tax Rate (6.0%)', BigDecimal('6.0'), 100_000, 6_000, 106_000],
      first.values_at(:business_date, :tax_rate_label, :rate_percent, :pre_tax_cents, :tax_cents, :total_cents)
    assert_nil untaxed[:rate_percent]
    assert_equal [-1_000, -60, -1_060], refund.values_at(:pre_tax_cents, :tax_cents, :total_cents)
  end

  test 'parses the sales report keeping blank amounts unknown' do
    rows = parse(SALES_CSV, topic: 'sales')
    assert_equal 2, rows.size
    assert_nil rows.first[:discounts_cents]
    assert_equal [10_000, 600, 100, 0, 10_700, 8_000, 2_700],
      rows.first.values_at(:subtotal_cents, :tax_cents, :tips_cents, :refunds_cents, :net_sales_cents, :net_card_cents, :net_cash_cents)
    assert_equal(-500, rows.last[:refunds_cents])
  end

  test 'money parsing accepts only recognised formats' do
    { '$1,234.56' => 123_456, '1234.5' => 123_450, '.50' => 50, '($5.00)' => -500, '-$5' => -500, '$-5.00' => -500, ' 7 ' => 700 }.each do |raw, cents|
      assert_equal cents, SwipesimpleWeb::ReportCsv.cents(raw), raw
    end
    assert_nil SwipesimpleWeb::ReportCsv.cents('  ')
    ['1.2.3', 'USD 5', '12,34', '$', '-', '--5', '(-$5)', '1.234', '5%'].each do |raw|
      assert_raises(SwipesimpleWeb::ReportCsv::Error, raw) { SwipesimpleWeb::ReportCsv.cents(raw) }
    end
  end

  test 'rejects totals that do not add up, dates outside the range and changed layouts' do
    bad = {
      'totals mismatch' => TAX_CSV.sub('Totals,,"$1,040.00"', 'Totals,,"$1,041.00"'),
      'blank day with a known total' => TAX_CSV.sub(',$50.00,$0.00,$50.00', ',$50.00,,$50.00'),
      'date outside range' => TAX_CSV.sub('04/02/2026', '03/31/2026'),
      'impossible date' => TAX_CSV.sub('04/02/2026', '04/31/2026'),
      'no Totals row' => TAX_CSV.lines[0..-2].join,
      'changed header' => TAX_CSV.sub('Total $ of Sales Tax', 'Sales Tax'),
      'repeated day and rate' => TAX_CSV.sub('04/01/2026,No Tax', '04/01/2026,PA Tax Rate (6.0%)'),
      'unknown money format' => TAX_CSV.sub('$60.00', '60 USD'),
      'extra column' => TAX_CSV.sub('$0.00,$50.00', '$0.00,$50.00,x')
    }
    bad.each do |label, text|
      assert_raises(SwipesimpleWeb::ReportCsv::Error, label) { parse(text) }
    end
    assert_empty parse(empty_report('tax'))
  end

  test 'client fetches long ranges month by month with only ISO start and end dates' do
    stub_reports
    chunks = client.report('sales', from: Date.new(2026, 8, 15), to: Date.new(2026, 10, 15))
    assert_equal [['2026-08-15', '2026-08-31'], ['2026-09-01', '2026-09-30'], ['2026-10-01', '2026-10-15']],
      chunks.map { |chunk| [chunk.from.iso8601, chunk.to.iso8601] }
    [%w[2026-08-15 2026-08-31], %w[2026-09-01 2026-09-30], %w[2026-10-01 2026-10-15]].each do |first, last|
      assert_requested :get, "https://swipesimple.com/companies/42/reports.csv?report%5Btopic%5D=sales&start_date=#{first}&end_date=#{last}", times: 1
    end
    assert_requested :post, 'https://login.cardflight.com/api/v1/login', times: 1
  end

  test 'a report that falls back to other dates is rejected' do
    stub_reports { |topic, _from, _to| topic == 'tax' ? TAX_CSV.gsub('04/0', '03/0') : nil }
    error = assert_raises(SwipesimpleWeb::Client::Error) { client.report('tax', from: APRIL.first, to: APRIL.last) }
    assert_equal :response, error.reason
  end

  test 'reports for another company path are refused before any request' do
    other = SwipesimpleWeb::Client.new(@connection.credential_values, company_id: '42')
    refute other.send(:allowed_url?, URI('https://swipesimple.com/companies/99/reports.csv'), 'GET')
    refute other.send(:allowed_url?, URI('https://swipesimple.com/companies/42/reports.csv'), 'POST')
    assert other.send(:allowed_url?, URI('https://swipesimple.com/companies/42/reports.csv?report%5Btopic%5D=tax'), 'GET')
    assert other.send(:allowed_url?, URI('https://swipesimple.com/items.xlsx'), 'GET')
    refute other.send(:allowed_url?, URI('https://swipesimple.com/items.xlsx'), 'POST')
  end

  test 're-pulling a month replaces its days atomically and keeps one coverage record' do
    stub_reports { |topic, _from, _to| topic == 'tax' ? TAX_CSV : nil }
    first = client.report('tax', from: APRIL.first, to: APRIL.last).sole
    SwipesimpleWeb::ReportStore.replace!(first, merchant_account: 'Example Wholesale')
    assert_equal 3, SwipesimpleTaxDay.count
    document = ReconciliationDocument.find(SwipesimpleReportPull.sole.reconciliation_document_id)
    assert_equal [APRIL.first, APRIL.last, 'swipesimple', 'processor_report'], [document.period_from, document.period_to, document.source, document.kind]

    smaller = TAX_CSV.lines.values_at(0, 1).join + "Totals,,\"$1,000.00\",$60.00,\"$1,060.00\"\n"
    second = SwipesimpleWeb::Client::ReportChunk.new(topic: 'tax', from: APRIL.first, to: APRIL.last, text: smaller,
      rows: parse(smaller), sha256: Digest::SHA256.hexdigest(smaller), exported_at: Time.current.iso8601)
    SwipesimpleWeb::ReportStore.replace!(second, merchant_account: 'Example Wholesale')
    assert_equal [[Date.new(2026, 4, 1), 'PA Tax Rate (6.0%)']], SwipesimpleTaxDay.pluck(:business_date, :tax_rate_label)
    assert_equal 1, SwipesimpleReportPull.count

    broken = second.dup.tap { |chunk| chunk.rows = parse(TAX_CSV).each_with_index.map { |row, i| i == 2 ? row.merge(tax_rate_label: nil) : row } }
    assert_raises(ActiveRecord::RecordInvalid) { SwipesimpleWeb::ReportStore.replace!(broken, merchant_account: 'Example Wholesale') }
    assert_equal 1, SwipesimpleTaxDay.count, 'a failed replace keeps the previous days'
    assert_equal second.sha256, SwipesimpleReportPull.sole.source_digest
  end

  test 'sync stores the rolling report window and items; the current month is not filed as evidence' do
    stub_exports_for_sync
    stub_reports { |topic, from, _to| topic == 'sales' && from == '2026-10-01' ? SALES_CSV.gsub('04/0', '10/0') : nil }
    stub_items
    result = SwipesimpleWeb::Sync.call(connection: @connection)
    assert_equal %i[pulled updated], result.values_at(:reports, :items)
    assert_equal [%w[sales 2026-09-01 2026-09-30], %w[sales 2026-10-01 2026-10-15], %w[tax 2026-09-01 2026-09-30], %w[tax 2026-10-01 2026-10-15]],
      SwipesimpleReportPull.order(:topic, :period_from).map { |pull| [pull.topic, pull.period_from.iso8601, pull.period_to.iso8601] }
    assert_equal 2, SwipesimpleSalesDay.count
    assert_equal 2, ReconciliationDocument.where(source: 'swipesimple', kind: 'processor_report').count, 'only September is closed'
    assert_includes @connection.reload.last_report_message, 'Tax and sales reports pulled for 2026-09-01 through 2026-10-15.'
    snapshot = SwipesimpleItemSnapshot.sole
    assert snapshot.automatic?
    assert_equal %w[101 102], snapshot.records.map { |r| r['id'] }
  end

  test 'report and item failures are isolated from the transaction pull' do
    stub_exports_for_sync
    stub_reports
    stub_items
    SwipesimpleWeb::Sync.call(connection: @connection)
    before = SwipesimpleItemSnapshot.sole.captured_at
    travel 30.minutes
    stub_request(:get, %r{\Ahttps://swipesimple\.com/companies/42/reports\.csv}).to_return(status: 502, body: 'private upstream response')
    stub_items('not a workbook')
    result = nil
    assert_no_difference ['SwipesimpleReportPull.count', 'SwipesimpleTaxDay.count'] do
      result = SwipesimpleWeb::Sync.call(connection: @connection.reload)
    end
    assert_equal [13, 7, :failed, :failed], result.values_at(:transactions, :invoices, :reports, :items)
    @connection.reload
    assert_equal 'succeeded', @connection.last_report_status
    assert_includes @connection.last_report_message, 'Tax and sales reports were not updated'
    assert_includes @connection.last_report_message, 'Items were not updated'
    refute_includes @connection.last_report_message, 'private upstream'
    assert @connection.reporting_enabled
    assert_equal before, SwipesimpleItemSnapshot.sole.captured_at
  end

  test 'a report that cannot be stored keeps the transaction pull' do
    stub_exports_for_sync
    stub_reports
    stub_items
    SwipesimpleWeb::ReportStore.stubs(:replace!).raises(ActiveRecord::RecordInvalid.new(SwipesimpleTaxDay.new))
    result = SwipesimpleWeb::Sync.call(connection: @connection)
    assert_equal :failed, result[:reports]
    assert_equal 2, SwipesimpleExport.count
    assert_includes @connection.reload.last_report_message, 'could not be stored'
  end

  test 'items workbook parses sheets by name with shared or inline strings and resolves tax' do
    [true, false].each do |shared|
      records = SwipesimpleWeb::ItemsWorkbook.parse(items_xlsx(shared_strings: shared, sheets: %w[Taxes Instructions Items]))
      assert_equal %w[101 102], records.map { |r| r['id'] }, 'removed items are left out'
      flower, papers = records
      assert_equal ['Blue Dream Flower 3.5g', 'BD-35', '35.0', 3500, '12', true, 'PA Tax', '6.0', 'Flower'],
        flower.values_at('name', 'sku', 'price', 'price_cents', 'quantity', 'manage_stock', 'tax_label', 'tax_rate', 'category')
      assert_nil papers['sku']
      assert_nil papers['quantity'], 'untracked stock is unknown, not zero'
      refute papers['manage_stock']
      assert_equal ['No Tax', '0.0', 990], papers.values_at('tax_label', 'tax_rate', 'price_cents')
      assert_equal flower['name'], flower['product_name']
      assert_nil flower['variant']
    end
    unknown = SwipesimpleWeb::ItemsWorkbook.parse(items_xlsx(items: [[7, 'Gift', nil, 5, 'Mystery Tax', 'active', true, 3, nil]]))
    assert_equal ['Mystery Tax', nil, '3', true], unknown.first.values_at('tax_label', 'tax_rate', 'quantity', 'manage_stock')
  end

  test 'items workbook fails closed on missing sheets, changed headers and bad values' do
    {
      'missing Taxes' => items_xlsx(sheets: %w[Instructions Items]),
      'changed header' => items_xlsx(item_headers: %w[id title sku price tax status track_inventory on_hand_count category]),
      'unknown status' => items_xlsx(items: [[7, 'Gift', nil, 5, 'No Tax', 'hidden', 'true', 3, nil]]),
      'bad quantity' => items_xlsx(items: [[7, 'Gift', nil, 5, 'No Tax', 'active', 'true', 'lots', nil]]),
      'duplicate id' => items_xlsx(items: [[7, 'Gift', nil, 5, 'No Tax', 'active', 'true', 3, nil], [7, 'Gift 2', nil, 5, 'No Tax', 'active', 'true', 3, nil]]),
      'not a zip' => 'plain text'
    }.each do |label, bytes|
      assert_raises(SwipesimpleWeb::ItemsWorkbook::Error, label) { SwipesimpleWeb::ItemsWorkbook.parse(bytes) }
    end
  end

  test 'an unchanged item workbook does not replace the snapshot' do
    stub_exports_for_sync
    stub_reports
    stub_items
    SwipesimpleWeb::Sync.call(connection: @connection)
    captured = SwipesimpleItemSnapshot.sole.captured_at
    travel 30.minutes
    assert_equal :unchanged, SwipesimpleWeb::Sync.call(connection: @connection.reload)[:items]
    assert_equal captured, SwipesimpleItemSnapshot.sole.captured_at
    assert_includes @connection.reload.last_report_message, 'Item list unchanged.'
  end

  test 'backfill pulls month by month for the verified account only' do
    account_export!
    stub_reports { |topic, from, _to| topic == 'tax' && from == '2026-04-01' ? TAX_CSV : nil }
    lines = []
    result = SwipesimpleWeb::Backfill.call(connection: @connection, from: Date.new(2026, 3, 20), to: APRIL.last, pause: 0, log: ->(line) { lines << line })
    assert_equal 2, result[:months]
    assert_equal 4, lines.size
    assert_equal 4, SwipesimpleReportPull.count
    assert_equal 3, SwipesimpleTaxDay.where(merchant_account: 'Example Wholesale').count
    assert_raises(ArgumentError) { SwipesimpleWeb::Backfill.call(connection: @connection, from: APRIL.first, to: Date.new(2027, 1, 1), pause: 0) }
  end

  private

  def stub_exports_for_sync
    %w[transactions invoices].each do |kind|
      text = File.binread(Rails.root.join("test/fixtures/files/swipesimple_#{kind}.csv")).force_encoding(Encoding::UTF_8).gsub('\\r\\n', "\r\n")
      total = CSV.parse(text.delete_prefix("﻿"), headers: true).size
      stub_request(:get, "https://swipesimple.com/#{kind}.json?iDisplayStart=0&iDisplayLength=1&sEcho=1")
        .to_return(json_response(iTotalRecords: total, iTotalDisplayRecords: total))
      stub_request(:get, "https://swipesimple.com/#{kind}.csv?time_zone=America%2FNew_York")
        .to_return(status: 200, body: text, headers: { 'Content-Type' => 'text/csv' })
    end
  end
end
