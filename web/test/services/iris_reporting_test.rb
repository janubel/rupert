# frozen_string_literal: true

require 'test_helper'

class IrisReportingTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
    @origin = 'https://synthetic.iriscrm.com'
    @connection = PosConnection.create!(provider: 'iris_reporting', environment: 'production', account_reference: '12345',
      vendor_approved: true, credentials_json: { api_url: @origin, api_token: 'synthetic-token' }.to_json)
    @from = Date.new(2026, 10, 1)
    @to = Date.new(2026, 10, 15)
    @calls = []
    @on_request = nil
    stub_request(:get, %r{\Ahttps://synthetic\.iriscrm\.com/api/v1/merchants/[0-9]+/}).to_return do |req|
      @calls << req
      @on_request&.call
      body = if req.uri.path.include?('/deposits/')
        { deposits: [{ date: '10/15/2026', amount: '9.25', transactions: 1, batch: 'batch-1' }],
          adjustments: [{ date: '10/15/2026', type: 'Adjustment', amount: '-1.00' }], totals: {} }
      else
        data = req.uri.path.end_with?('/transactions') ? [batch] : []
        { data: data, meta: { current_page: 1, last_page: '1', total: data.size }, links: { next: 'https://evil.invalid/token' } }
      end
      { status: 200, headers: { 'Content-Type' => 'application/json' }, body: body.to_json }
    end
  end

  teardown { Current.reset }

  test 'API imports encrypted sanitized snapshots with replay safety and signed adjustments' do
    2.times { import }
    assert_equal 5, IrisReport.count
    report = IrisReport.find_by!(report_kind: 'transactions')
    assert_equal '42', report.payload['data'].first['transactions'].first['id'].to_s
    refute_includes report.payload_json, 'PRIVATE CARD'
    refute_includes report.payload_json, 'PRIVATE CUSTOMER'
    assert_equal '-1.0', IrisReport.find_by!(report_kind: 'deposits').payload['adjustments'].first['amount']
    raw = IrisReport.connection.select_value("SELECT payload_json FROM iris_reports WHERE id = #{report.id}")
    refute_includes raw, 'transactions'
    assert @calls.all? { |req| req.method == :get && req.headers['X-Api-Key'] == 'synthetic-token' }
    assert_equal 'complete', @connection.reload.last_report_status
  end

  test 'merchant and workspace identities stay separate' do
    @connection.update!(account_reference: '12345, 67890')
    import
    assert_equal 10, IrisReport.count
    assert_equal %w[12345 67890], IrisReport.distinct.pluck(:merchant_number).sort
    Current.tenant = Tenant.create!(name: 'Other IRIS workspace', subdomain: 'other-iris', status: 'active')
    assert_equal 0, IrisReport.count
    assert_raises(IrisReporting::Client::Error) { import }
  end

  test 'optional reports denied by vendor are unavailable, never empty zero reports' do
    stub_request(:get, %r{/chargebacks\?}).to_return(status: 403, body: 'PRIVATE ERROR')
    import
    assert_equal 'partial', @connection.reload.last_report_status
    report = IrisReport.find_by!(report_kind: 'chargebacks')
    assert_equal 'unavailable', report.status
    refute_includes report.payload_json, 'PRIVATE ERROR'
    refute report.payload.key?('data')
  end

  test 'required report failure is atomic and sanitized' do
    import
    before = IrisReport.order(:id).pluck(:payload_json, :observed_at)
    stub_request(:get, %r{/deposits/}).to_return(status: 401, body: 'PRIVATE ERROR TOKEN')
    error = assert_raises(IrisReporting::Client::Error) { import }
    refute_includes error.message, 'PRIVATE'
    assert_equal before, IrisReport.order(:id).pluck(:payload_json, :observed_at)
  end

  test 'changed setup cannot persist an obsolete queued result' do
    @on_request = lambda do
      @on_request = nil
      PosConnection.find(@connection.id).update!(account_reference: '67890')
    end
    assert_raises(IrisReporting::Client::Error) { import }
    assert_equal 0, IrisReport.count
  end

  test 'incomplete and repeated pages cannot be reported complete or follow vendor next URL' do
    stub_request(:get, %r{/transactions\?}).to_return(status: 200, headers: { 'Content-Type' => 'application/json' },
      body: { data: [batch], meta: { current_page: 1, last_page: 1, total: 2 } }.to_json)
    assert_raises(IrisReporting::Client::Error) { import }
    assert_equal 0, IrisReport.count
    stub_request(:get, %r{/transactions\?}).to_return do |req|
      page = URI.decode_www_form(req.uri.query).to_h['page'].to_i
      { status: 200, headers: { 'Content-Type' => 'application/json' },
        body: { data: [batch], meta: { current_page: page, last_page: '2', total: 2 } }.to_json }
    end
    assert_raises(IrisReporting::Client::Error) { import }
    assert_equal 0, IrisReport.count
  end

  test 'redirects rate limits oversized responses invalid hosts and bad numbers fail safely' do
    %w[http://synthetic.iriscrm.com https://127.0.0.1 https://synthetic.iriscrm.com.evil.invalid https://synthetic.iriscrm.com:444 https://synthetic.iriscrm.com/path].each do |origin|
      refute IrisReporting::Client.valid_credentials?({ 'api_url' => origin, 'api_token' => 'test' })
    end
    assert_raises(IrisReporting::Client::Error) { IrisReporting::Client.merchants('123,123') }
    stub_request(:get, %r{/transactions\?}).to_return(status: 302, headers: { 'Location' => 'https://evil.invalid' })
    assert_raises(IrisReporting::Client::Error) { import }
    stub_request(:get, %r{/transactions\?}).to_return(status: 429, body: 'PRIVATE')
    assert_raises(IrisReporting::Client::Error) { import }
    stub_request(:get, %r{/transactions\?}).to_return(status: 200,
      headers: { 'Content-Type' => 'application/json', 'Content-Length' => (IrisReporting::Client::MAX_BYTES + 1).to_s })
    assert_raises(IrisReporting::Client::Error) { import }
    assert_raises(IrisReporting::Client::Error) { IrisReporting::Import.clean('transaction', { 'amount' => 'NaN' }) }
  end

  test 'diagnostics read actual required reports without importing' do
    assert_equal 'verified', IrisReporting::Check.call(connection: @connection)[:status]
    assert_equal 0, IrisReport.count
    assert_equal 2, @calls.size
  end

  test 'successful multi-page reads use locally constructed page numbers' do
    stub_request(:get, %r{/transactions\?}).to_return do |req|
      page = URI.decode_www_form(req.uri.query).to_h.fetch('page').to_i
      { status: 200, headers: { 'Content-Type' => 'application/json' },
        body: { data: [batch.merge(id: page)], meta: { current_page: page, last_page: '2', total: 2 },
          links: { next: 'https://evil.invalid' } }.to_json }
    end
    import
    assert_equal [1, 2], IrisReport.find_by!(report_kind: 'transactions').payload['data'].pluck('id')
  end

  test 'optional statement response without complete metadata preserves prior data with a warning' do
    import
    stub_request(:get, %r{/statements\?}).to_return(status: 200, headers: { 'Content-Type' => 'application/json' },
      body: { data: [{ id: 7, date: 'October 2026' }] }.to_json)
    import
    report = IrisReport.find_by!(report_kind: 'statements')
    assert_equal 'unavailable', report.status
    assert_equal [], report.payload['data']
    assert report.payload.key?('read_warning')
  end

  test 'scheduler is opt in and stale manual jobs or disconnected credentials do not run' do
    IrisReporting::Import.expects(:call).never
    IrisReportingJob.perform_now
    IrisReportingJob.perform_now(tenant_id: @connection.tenant_id, connection_id: @connection.id, setup_version: 999)
    @connection.update!(credentials_json: '{}')
    IrisReportingJob.perform_now(tenant_id: @connection.tenant_id, connection_id: @connection.id)
  end

  test 'canonical monthly CSV is replay safe and does not create retail transactions' do
    csv = "period,metric,value\n2026-10,gross_sales,10.00\n2026-10,returns,1.00\n2026-10,net_sales,9.00\n"
    2.times { assert_equal 1, IrisReporting::CsvImport.call(text: csv, merchant: '12345', kind: 'sales_health_csv', year: nil) }
    assert_equal 1, IrisReport.count
    assert_equal 'sales_health_csv', IrisReport.first.report_kind
    assert_equal Digest::SHA256.hexdigest(csv), IrisReport.first.source_digest
    assert_empty @calls
  end

  test 'English monthly matrix requires an explicit end year and handles a year boundary' do
    csv = ",December,January,Total\nGross Sales,10.00,20.00,30.00\nReturns,1.00,2.00,3.00\nNet Sales,9.00,18.00,27.00\n"
    assert_raises(IrisReporting::Client::Error) { IrisReporting::CsvImport.call(text: csv, merchant: '12345', kind: 'sales_health_csv', year: nil) }
    assert_equal 2, IrisReporting::CsvImport.call(text: csv, merchant: '12345', kind: 'sales_health_csv', year: 2026)
    assert_equal [Date.new(2025, 12, 1), Date.new(2026, 1, 1)], IrisReport.order(:window_from).pluck(:window_from)
  end

  test 'invalid CSV totals duplicate metrics unsupported layouts and fractions in counts cannot mutate saved reports' do
    ["period,metric,value\n2026-10,gross_sales,10\n2026-10,returns,1\n2026-10,net_sales,100\n",
      "period,metric,value\n2026-10,gross_sales,10\n2026-10,gross_sales,10\n",
      "unexpected,layout\nprivate,data\n"].each do |csv|
      assert_raises(IrisReporting::Client::Error) { IrisReporting::CsvImport.call(text: csv, merchant: '12345', kind: 'sales_health_csv', year: 2026) }
    end
    assert_raises(IrisReporting::Client::Error) { IrisReporting::CsvImport.value('1.5', 'returns_count') }
    assert_equal 0, IrisReport.count
  end

  test 'transaction health matrix keeps amounts and counts separate' do
    csv = "Volume ($),October\nReturns ($),5.25\nChargebacks ($),0\nRetrievals ($),0\nVolume (Count),October\nReturns (Count),1\nChargebacks (Count),0\nRetrievals (Count),0\n"
    assert_equal 1, IrisReporting::CsvImport.call(text: csv, merchant: '12345', kind: 'transaction_health_csv', year: 2026)
    assert_equal '5.25', IrisReport.first.payload['data'].find { |row| row['metric'] == 'returns_amount' }['value']
    assert_equal '1.0', IrisReport.first.payload['data'].find { |row| row['metric'] == 'returns_count' }['value']
  end

  private

  def import
    IrisReporting::Import.call(connection: @connection, from: @from, to: @to)
  end

  def batch
    { id: 7, date: '10/15/2026', reference_number: 'synthetic-batch', amount: '9.25', count: '1',
      transactions: [{ id: 42, date: '10/15/2026', type: 'SALE', amount: '9.25',
        cardholder: 'PRIVATE CARD', customer: 'PRIVATE CUSTOMER', void_reject_chargeback: false }] }
  end
end
