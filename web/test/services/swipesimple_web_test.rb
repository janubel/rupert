# frozen_string_literal: true

require 'test_helper'
require 'csv'

class SwipesimpleWebTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  setup do
    Current.tenant = tenants(:default_tenant)
    travel_to Time.iso8601('2026-10-16T03:00:00Z')
    @credentials = { 'web_email' => 'reader@example.invalid', 'web_password' => 'private-login' }
    @connection = PosConnection.create!(provider: 'swipesimple', environment: 'production', account_reference: '42',
      vendor_approved: true, reporting_enabled: true, credentials_json: @credentials.to_json)
    stub_login
    stub_exports
  end

  teardown do
    travel_back
    Current.reset
  end

  test 'own login reads full exports with isolated cookies and never makes business writes' do
    assert_no_difference ['Core::Order.count', 'Core::Payment.count', 'LedgerEntry.count'] do
      assert_equal({ transactions: 13, invoices: 7 }, SwipesimpleWeb::Sync.call(connection: @connection))
    end
    assert_equal 2, SwipesimpleExport.count
    assert_equal 20, SwipesimpleReportRow.count
    assert_equal 'succeeded', @connection.reload.last_report_status
    assert_equal Time.current, @connection.last_reported_at
    assert_equal 'Live', SourceSyncStatus.all.find { |item| item[:key] == 'swipesimple' }[:badge]
    assert_requested :post, 'https://login.cardflight.com/api/v1/login', times: 1
    assert_requested :get, 'https://swipesimple.com/transactions.csv?time_zone=America%2FNew_York', times: 1
    assert_requested :get, 'https://swipesimple.com/invoices.csv?time_zone=America%2FNew_York', times: 1
    raw = PosConnection.connection.select_value("SELECT credentials_json FROM pos_connections WHERE id = #{@connection.id}")
    refute_includes raw, 'private-login'
    refute_includes @connection.last_report_message, 'private-login'
  end

  test 'each unchanged poll signs in and downloads again without duplicating snapshots' do
    SwipesimpleWeb::Sync.call(connection: @connection)
    first_read = @connection.reload.last_reported_at
    travel 30.minutes
    assert_no_difference ['SwipesimpleExport.count', 'SwipesimpleReportRow.count'] do
      SwipesimpleWeb::Sync.call(connection: @connection.reload)
    end
    assert_operator @connection.reload.last_reported_at, :>, first_read
    assert_requested :post, 'https://login.cardflight.com/api/v1/login', times: 2
    assert_requested :get, 'https://swipesimple.com/transactions.csv?time_zone=America%2FNew_York', times: 2
    assert_requested :get, 'https://swipesimple.com/invoices.csv?time_zone=America%2FNew_York', times: 2
  end

  test 'second export failure keeps both prior snapshots and successful read timestamp' do
    SwipesimpleWeb::Sync.call(connection: @connection)
    before = @connection.reload.last_reported_at
    stub_request(:get, /swipesimple.com\/invoices.csv/).to_return(status: 502, body: 'private upstream response')
    travel 30.minutes
    assert_no_difference ['SwipesimpleExport.count', 'SwipesimpleReportRow.count'] do
      error = assert_raises(SwipesimpleWeb::Client::Error) { SwipesimpleWeb::Sync.call(connection: @connection.reload) }
      refute_includes error.message, 'private upstream'
    end
    assert_equal before, @connection.reload.last_reported_at
    assert_equal 'failed', @connection.last_report_status
    assert @connection.reporting_enabled
  end

  test 'second importer failure rolls back the first snapshot in the same publication' do
    text = fixture('invoices').sub('unpaid', 'paid')
    options = { kind: 'invoices', merchant_account: 'Example Wholesale', currency: 'USD', source_timezone: 'America/New_York',
      exported_at: Time.current.utc.iso8601(6), invoice_scope: 'full' }
    prepared = SwipesimpleReportImporter.preview(text, options)
    SwipesimpleReportImporter.import!(text, options, expected_fingerprint: prepared.fingerprint)
    assert_no_difference ['SwipesimpleExport.count', 'SwipesimpleReportRow.count'] do
      assert_raises(SwipesimpleWeb::Client::Error) { SwipesimpleWeb::Sync.call(connection: @connection) }
    end
    assert_equal 0, SwipesimpleExport.where(kind: 'transactions').count
    assert_nil @connection.reload.last_reported_at
  end

  test 'bad passwords and verification pause automatic login attempts' do
    %w[Failed InProgress].each do |status|
      stub_request(:post, 'https://login.cardflight.com/api/v1/login').to_return(json_response(data: { status: status }))
      assert_no_difference 'SwipesimpleExport.count' do
        error = assert_raises(SwipesimpleWeb::Client::Error) { SwipesimpleWeb::Sync.call(connection: @connection.reload) }
        assert error.login_required?
      end
      assert_equal 'needs_login', @connection.reload.last_report_status
      refute @connection.reporting_enabled
      assert_equal 'Needs login', SourceSyncStatus.all.find { |item| item[:key] == 'swipesimple' }[:badge]
      assert_no_enqueued_jobs { SwipesimpleWebSyncJob.perform_now }
    end
    assert_not_requested :get, /swipesimple.com\/transactions.csv/
  end

  test 'incomplete counts changed totals and oversized exports cannot publish' do
    [{}, { iTotalRecords: 14, iTotalDisplayRecords: 14 }, { iTotalRecords: 13, iTotalDisplayRecords: 12 },
     { iTotalRecords: 10_001, iTotalDisplayRecords: 10_001 }].each do |counts|
      stub_request(:get, /swipesimple.com\/transactions.json/).to_return(json_response(counts))
      assert_no_difference 'SwipesimpleExport.count' do
        assert_raises(SwipesimpleWeb::Client::Error) { SwipesimpleWeb::Sync.call(connection: @connection.reload) }
      end
    end
  end

  test 'wrong company and merchant accounts cannot replace snapshots' do
    stub_request(:get, 'https://swipesimple.com/transactions').to_return(status: 200, body: '<a href="/companies/99/dashboard">Other company</a>')
    assert_equal :identity, assert_raises(SwipesimpleWeb::Client::Error) { SwipesimpleWeb::Sync.call(connection: @connection) }.reason
    stub_login
    SwipesimpleWeb::Sync.call(connection: @connection.reload)
    stub_exports(transaction_text: fixture('transactions').gsub('Example Wholesale', 'Other Merchant'))
    assert_no_difference 'SwipesimpleExport.count' do
      assert_equal :identity, assert_raises(SwipesimpleWeb::Client::Error) { SwipesimpleWeb::Sync.call(connection: @connection.reload) }.reason
    end
  end

  test 'outside hosts insecure redirects and unexpected write paths are rejected before requests' do
    ['https://outside.example.invalid/login', 'http://swipesimple.com/sign_in_v2', 'https://swipesimple.com/transactions/new', 'https://login.cardflight.com/api/v1/login/endSession'].each do |destination|
      stub_request(:get, 'https://swipesimple.com/sign_in').to_return(status: 302, headers: { 'Location' => destination })
      assert_raises(SwipesimpleWeb::Client::Error) { SwipesimpleWeb::Sync.call(connection: @connection.reload) }
      assert_not_requested :get, destination
    end
  end

  test 'verified provider login redirect is upgraded to HTTPS without an HTTP request' do
    stub_request(:get, 'https://swipesimple.com/sign_in').to_return(status: 302, headers: { 'Location' => 'https://login.cardflight.com/connect/authorize' })
    stub_request(:get, 'https://login.cardflight.com/connect/authorize').to_return(status: 302,
      headers: { 'Location' => "http://login.cardflight.com/login?ReturnUrl=#{URI.encode_www_form_component('/connect/authorize/callback?state=fixture')}" })
    SwipesimpleWeb::Sync.call(connection: @connection)
    assert_not_requested :get, %r{\Ahttp://}
  end

  test 'setup changes during network read discard both exports' do
    stub_request(:get, /swipesimple.com\/invoices.csv/).to_return do
      @connection.reload.update!(reporting_enabled: false)
      { status: 200, body: fixture('invoices'), headers: { 'Content-Type' => 'text/csv' } }
    end
    assert_no_difference 'SwipesimpleExport.count' do
      assert_equal :changed, assert_raises(SwipesimpleWeb::Client::Error) { SwipesimpleWeb::Sync.call(connection: @connection.reload) }.reason
    end
  end

  test 'simultaneous in-progress pull skips requests and tenant mismatch cannot read credentials' do
    @connection.update!(last_report_status: 'running', updated_at: Time.current)
    assert_equal({ busy: true }, SwipesimpleWeb::Sync.call(connection: @connection))
    assert_not_requested :post, 'https://login.cardflight.com/api/v1/login'
    Current.tenant = Tenant.create!(id: 'swipe-other', subdomain: 'swipe-other', name: 'Other', status: 'active')
    assert_equal :invalid, assert_raises(SwipesimpleWeb::Client::Error) { SwipesimpleWeb::Sync.call(connection: @connection) }.reason
  end

  test 'scheduled fanout and manual pull honor workspace status and schedule permissions' do
    assert_enqueued_with(job: SwipesimpleWebSyncJob, args: [@connection.id]) { SwipesimpleWebSyncJob.perform_now }
    @connection.update!(reporting_enabled: false)
    assert_no_enqueued_jobs { SwipesimpleWebSyncJob.perform_now }
    SwipesimpleWebSyncJob.perform_now(@connection.id)
    assert_not_requested :post, 'https://login.cardflight.com/api/v1/login'
    SwipesimpleWebSyncJob.perform_now(@connection.id, manual: true)
    assert_equal 2, SwipesimpleExport.count
    @connection.tenant.update!(status: 'suspended')
    SwipesimpleWebSyncJob.perform_now(@connection.id, manual: true)
    assert_requested :post, 'https://login.cardflight.com/api/v1/login', times: 1
  end

  private

  def fixture(kind)
    File.binread(Rails.root.join("test/fixtures/files/swipesimple_#{kind}.csv")).force_encoding(Encoding::UTF_8).gsub('\\r\\n', "\r\n")
  end

  def json_response(document)
    { status: 200, body: document.to_json, headers: { 'Content-Type' => 'application/json' } }
  end

  def stub_login
    return_url = '/connect/authorize/callback?state=fixture'
    login_url = "https://login.cardflight.com/login?ReturnUrl=#{URI.encode_www_form_component(return_url)}"
    stub_request(:get, 'https://swipesimple.com/sign_in').to_return(status: 302,
      headers: { 'Location' => login_url, 'Set-Cookie' => 'swipe=own-session; Path=/; Secure' })
    stub_request(:get, login_url).to_return(status: 200, body: '<html>Sign in</html>')
    stub_request(:get, "https://login.cardflight.com/api/v1/login/context?returnUrl=#{URI.encode_www_form_component(return_url)}")
      .to_return(json_response(data: { clientId: 'fixture-client' }))
    stub_request(:post, 'https://login.cardflight.com/api/v1/login').with { |request| !request.headers['Cookie'].to_s.include?('swipe=') }
      .to_return(json_response(data: { status: 'Authenticated' }).merge(headers: { 'Content-Type' => 'application/json', 'Set-Cookie' => 'cardflight=own-login; Path=/; Secure' }))
    stub_request(:get, "https://login.cardflight.com#{return_url}").to_return(status: 302,
      headers: { 'Location' => 'https://swipesimple.com/companies/42/dashboard' })
    stub_request(:get, 'https://swipesimple.com/companies/42/dashboard').to_return(status: 200, body: '<html>Dashboard</html>')
    stub_request(:get, 'https://swipesimple.com/transactions').with { |request| !request.headers['Cookie'].to_s.include?('cardflight=') }
      .to_return(status: 200, body: '<a href="/companies/42/dashboard">Company</a>')
  end

  def stub_exports(transaction_text: fixture('transactions'))
    %w[transactions invoices].each do |kind|
      text = kind == 'transactions' ? transaction_text : fixture(kind)
      total = CSV.parse(text.delete_prefix("\uFEFF"), headers: true).size
      stub_request(:get, "https://swipesimple.com/#{kind}.json?iDisplayStart=0&iDisplayLength=1&sEcho=1")
        .to_return(json_response(iTotalRecords: total, iTotalDisplayRecords: total))
      stub_request(:get, "https://swipesimple.com/#{kind}.csv?time_zone=America%2FNew_York")
        .to_return(status: 200, body: text, headers: { 'Content-Type' => 'text/csv' })
    end
  end
end
