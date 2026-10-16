# frozen_string_literal: true

require 'test_helper'

class IrisWebReportingTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  setup do
    Current.tenant = tenants(:default_tenant)
    travel_to Time.utc(2026, 10, 16, 2, 0)
    @connection = PosConnection.create!(provider: 'iris_reporting', reporting_auth_mode: 'web', environment: 'production',
      account_reference: '12345', vendor_approved: true, reporting_enabled: true,
      credentials_json: { web_username: 'synthetic-nab-user', web_password: 'synthetic-private-password' }.to_json)
    @calls = []
    @on_export = nil
    origin = IrisReporting::WebClient::ORIGIN
    page = '<html><head><meta name="csrf-token" content="synthetic-csrf"></head></html>'
    stub_request(:get, "#{origin}/v2/login?ref=%2Fmerchant-portal").to_return(status: 200, body: page,
      headers: { 'Content-Type' => 'text/html', 'Set-Cookie' => 'session=synthetic-session; Path=/; Secure; HttpOnly' })
    stub_request(:post, "#{origin}/v2/login").to_return do |req|
      @calls << req
      { status: 200, headers: { 'Content-Type' => 'application/json' }, body: { success: 1, isMerchant: true }.to_json }
    end
    stub_request(:get, "#{origin}/merchant-portal").to_return(status: 200, body: page, headers: { 'Content-Type' => 'text/html' })
    stub_request(:post, "#{origin}/graphql/web").to_return do |req|
      @calls << req
      document = JSON.parse(req.body)
      vars = document.fetch('variables')
      assert_equal 'deposits', vars.fetch('batches') unless document.fetch('query').include?('RupertMerchant')
      data = if document.fetch('query').include?('RupertMerchant')
        { merchants: { total: 1, data: [{ mid: vars.fetch('mid') }] } }
      elsif document.fetch('query').include?('RupertDailyDeposits')
        { merchantDailyDeposits: { data: [row(vars)], total: { amount: '12.34', transactions: 2 } } }
      else
        @on_export&.call
        { merchantDailyDeposits: { data: nil, exportUrl: "https://cdn.iriscrm.com/nabankco/tmp/synthetic-#{vars.fetch('year')}-#{vars.fetch('month')}.csv?download=1" } }
      end
      { status: 200, headers: { 'Content-Type' => 'application/json' }, body: { data: data }.to_json }
    end
    stub_request(:get, %r{\Ahttps://cdn\.iriscrm\.com/nabankco/tmp/synthetic-2026-[0-9]+\.csv\?download=1\z}).to_return do |req|
      @calls << req
      month = req.uri.path[/2026-([0-9]+)/, 1].to_i
      { status: 200, headers: { 'Content-Type' => 'application/octet-stream' }, body: csv(month) }
    end
  end

  teardown do
    Current.reset
    travel_back
  end

  test 'fresh website login downloads both months without browser state and isolates CDN credentials' do
    snapshots = IrisReporting::WebClient.new(@connection.credential_values).fetch(merchants: %w[12345], months: [Date.new(2026, 9, 1), Date.new(2026, 10, 1)])
    assert_equal %w[2026-09 2026-10], snapshots.map(&:period)
    assert_equal ['000001'], snapshots.first.rows.pluck('batch')
    assert_empty IrisReport.all
    login = @calls.find { |req| req.uri.path == '/v2/login' }
    assert_includes login.headers['Cookie'], 'session=synthetic-session'
    assert_equal 'synthetic-csrf', login.headers['X-Csrf-Token']
    @calls.select { |req| req.uri.host == 'cdn.iriscrm.com' }.each do |req|
      assert_nil req.headers['Cookie']
      assert_nil req.headers['X-Csrf-Token']
    end
    assert @calls.select { |req| req.method == :post }.all? { |req| %w[/v2/login /graphql/web].include?(req.uri.path) }
  end

  test 'scheduled web imports are encrypted replay safe and never duplicate canonical records' do
    assert_no_difference ['Core::Order.unscoped.count', 'LedgerEntry.unscoped.count'] do
      2.times { assert_equal({ snapshots: 2 }, IrisReporting::WebSync.call(connection: @connection.reload)) }
    end
    assert_equal 2, IrisReport.count
    assert_equal 2, ReconciliationDocument.count
    assert_equal [csv(9), csv(10)].sort, ReconciliationDocument.all.map(&:original_bytes).sort
    assert_equal ['daily_deposits_csv'], IrisReport.distinct.pluck(:report_kind)
    assert_equal 'complete', @connection.reload.last_report_status
    assert_equal 'verified', @connection.last_check_status
    assert @connection.reporting_enabled
    raw = PosConnection.connection.select_value("SELECT credentials_json FROM pos_connections WHERE id = #{@connection.id}")
    refute_includes raw, 'synthetic-private-password'
    assert_equal 'Live', SourceSyncStatus.all.find { |source| source[:key] == 'bank' }[:badge]
  end

  test 'credential failure and additional verification pause scheduled pulls and retain reports' do
    IrisReporting::WebSync.call(connection: @connection)
    prior = IrisReport.order(:id).pluck(:payload_json, :observed_at)
    [401, 403].each do |status|
      @connection.update!(reporting_enabled: true)
      stub_request(:post, "#{IrisReporting::WebClient::ORIGIN}/v2/login").to_return(status: status, body: 'PRIVATE VENDOR DETAILS')
      error = assert_raises(IrisReporting::WebClient::Error) { IrisReporting::WebSync.call(connection: @connection.reload) }
      refute_includes error.message, 'PRIVATE'
      assert_equal 'needs_login', @connection.reload.last_report_status
      refute @connection.reporting_enabled
      assert_equal prior, IrisReport.order(:id).pluck(:payload_json, :observed_at)
    end
  end

  test 'incomplete native or JSON reports abort the complete pull and retain previous snapshots' do
    IrisReporting::WebSync.call(connection: @connection)
    prior = IrisReport.order(:id).pluck(:payload_json, :observed_at)
    stub_request(:get, 'https://cdn.iriscrm.com/nabankco/tmp/synthetic-2026-10.csv?download=1').to_return(
      status: 200, headers: { 'Content-Type' => 'text/csv' }, body: csv(10).sub('Monthly Total,12.34', 'Monthly Total,99.00'))
    assert_raises(IrisReporting::WebClient::Error) { IrisReporting::WebSync.call(connection: @connection.reload) }
    assert_equal prior, IrisReport.order(:id).pluck(:payload_json, :observed_at)
    assert_equal 'failed', @connection.reload.last_report_status
    assert @connection.reporting_enabled
  end

  test 'setup changes during network reads cannot publish obsolete credentials or snapshots' do
    @on_export = -> { @connection.reload.update!(reporting_enabled: false) }
    assert_raises(IrisReporting::WebClient::Error) { IrisReporting::WebSync.call(connection: @connection) }
    assert_equal 0, IrisReport.count
    refute @connection.reload.reporting_enabled
    assert_nil @connection.last_report_status
  end

  test 'foreign merchant identity arbitrary export hosts redirects and malformed JSON are rejected' do
    origin = IrisReporting::WebClient::ORIGIN
    stub_request(:post, "#{origin}/graphql/web").to_return(status: 200, headers: { 'Content-Type' => 'application/json' },
      body: { data: { merchants: { total: 1, data: [{ mid: '67890' }] } } }.to_json)
    error = assert_raises(IrisReporting::WebClient::Error) { fetch }
    assert_equal :identity, error.reason
    client = IrisReporting::WebClient.new(@connection.credential_values)
    %w[http://cdn.iriscrm.com/nabankco/tmp/file.csv https://evil.invalid/nabankco/tmp/file.csv https://cdn.iriscrm.com/other/tmp/file.csv https://cdn.iriscrm.com/nabankco/tmp/../file.csv].each do |url|
      refute client.send(:allowed_export_url?, URI(url))
    end
    stub_request(:post, "#{origin}/graphql/web").to_return(status: 200, headers: { 'Content-Type' => 'application/json' }, body: '{invalid')
    assert_raises(IrisReporting::WebClient::Error) { fetch }
    stub_request(:get, "#{origin}/v2/login?ref=%2Fmerchant-portal").to_return(status: 302, headers: { 'Location' => 'https://evil.invalid/' })
    assert_raises(IrisReporting::WebClient::Error) { fetch }
    assert_equal 0, IrisReport.count
  end

  test 'web scheduler is opt in and API scheduler never uses website credentials' do
    @connection.update!(reporting_enabled: false)
    assert_no_enqueued_jobs { IrisDailyDepositsWebJob.perform_now }
    IrisReporting::Import.expects(:call).never
    IrisReportingJob.perform_now
    IrisReporting::WebSync.expects(:call).once.with(connection: @connection).returns(snapshots: 2)
    IrisDailyDepositsWebJob.perform_now(@connection.id, manual: true, setup_version: @connection.lock_version)
    IrisDailyDepositsWebJob.perform_now(@connection.id, manual: true, setup_version: -1)
    @connection.update!(reporting_enabled: true)
    assert_enqueued_with(job: IrisDailyDepositsWebJob, args: [@connection.id]) { IrisDailyDepositsWebJob.perform_now }
  end

  test 'native total row allows only bounded empty padding and rejects aggregate data in reference cells' do
    [4, 5, 6].each do |width|
      text = csv(10, total_width: width)
      assert_equal '12.34', IrisReporting::DailyDepositsCsvImport.parse(text: text, period: '2026-10')['totals']['amount']
    end
    assert_raises(IrisReporting::Client::Error) { IrisReporting::DailyDepositsCsvImport.parse(text: csv(10, total_width: 7), period: '2026-10') }
    assert_raises(IrisReporting::Client::Error) { IrisReporting::DailyDepositsCsvImport.parse(text: csv(10).sub('Monthly Total', 'Total Paid By Us'), period: '2026-10') }
    assert_raises(IrisReporting::Client::Error) { IrisReporting::DailyDepositsCsvImport.parse(text: csv(10).sub('Monthly Total,12.34,2,,', 'Monthly Total,12.34,2,batch,'), period: '2026-10') }
  end

  private

  def row(vars)
    { date: "#{vars.fetch('month')}/1/#{vars.fetch('year')}", amount: '12.34', transactions: 2,
      reference_number: '000001', terminal_number: nil, type: 0 }
  end

  def csv(month, total_width: 5)
    CSV.generate do |out|
      out << ['Daily Deposits']
      out << ['Records exported: 1']
      out << []
      out << IrisReporting::DailyDepositsCsvImport::HEADER
      out << ["#{month}/1/2026", '12.34', 2, '000001', nil, 0]
      out << ['Monthly Total', '12.34', 2, *Array.new(total_width - 3)]
    end
  end

  def fetch
    IrisReporting::WebClient.new(@connection.credential_values).fetch(merchants: %w[12345], months: [Date.new(2026, 10, 1)])
  end
end
