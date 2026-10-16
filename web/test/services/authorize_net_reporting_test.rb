# frozen_string_literal: true

require 'test_helper'

class AuthorizeNetReportingTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
    @connection = PosConnection.create!(provider: 'authorize_net_reporting', environment: 'sandbox',
      account_reference: '12345', vendor_approved: true,
      credentials_json: { api_login_id: 'synthetic-report-login', transaction_key: 'synthetic-key' }.to_json)
    @endpoint = AuthorizeNetReporting::Client::ENDPOINTS.fetch('sandbox')
    @calls = []
    @status = 'capturedPendingSettlement'
    @batch = false
    @tip = nil
    @total_override = nil
    @detail_failure = false
    @on_detail = nil
    @currencies = ['USD']
    stub_request(:post, @endpoint).to_return do |req|
      payload = JSON.parse(req.body)
      method = payload.keys.fetch(0)
      @calls << payload
      doc = case method
      when 'getMerchantDetailsRequest' then { gatewayId: '12345', currencies: @currencies, merchantName: 'Synthetic test merchant' }
      when 'getSettledBatchListRequest' then { batchList: @batch ? [batch] : [] }
      when 'getTransactionListRequest' then { transactions: [{ transId: '9001' }], totalNumInResultSet: 1 }
      when 'getUnsettledTransactionListRequest' then { transactions: @batch ? [] : [{ transId: '9001' }], totalNumInResultSet: @total_override || (@batch ? 0 : 1) }
      when 'getTransactionDetailsRequest'
        @on_detail&.call
        if @detail_failure
          { messages: { resultCode: 'Error', message: [{ code: 'E00007', text: 'SECRET error body' }] } }
        else
          { transaction: detail }
        end
      else
        raise "Unexpected API method #{method}"
      end
      { status: 200, body: success.merge(doc.stringify_keys).to_json, headers: { 'Content-Type' => 'application/json' } }
    end
  end

  teardown { Current.reset }

  test 'event imports fetch only verified current detail and do not claim full reconciliation freshness' do
    AuthorizeNetClient.expects(:charge!).never
    2.times { AuthorizeNetReporting::Import.call(connection: @connection, transaction_id: '9001') }
    assert_equal 1, AuthorizeNetTransaction.count
    assert_equal ['getMerchantDetailsRequest', 'getTransactionDetailsRequest'] * 2, @calls.map { |p| p.keys.first }
    assert_nil @connection.reload.last_reported_at
    assert_equal 0, Core::Order.count
    assert_equal 0, Core::Payment.count
    @status = 'voided'
    AuthorizeNetReporting::Import.call(connection: @connection, transaction_id: '9001')
    assert_equal 'voided', AuthorizeNetTransaction.first.payment_status
    assert_equal 2, AuthorizeNetTransaction.first.status_history.size
  end

  test 'older in-flight observations cannot replace newer gateway state' do
    import
    future = 2.minutes.from_now
    AuthorizeNetTransaction.first.update!(observed_at: future, payment_status: 'voided')
    import
    assert_equal 'voided', AuthorizeNetTransaction.first.payment_status
    assert_equal future.to_i, AuthorizeNetTransaction.first.observed_at.to_i
  end

  test 'import is replay safe and preserves settlement status history and optional tips' do
    @tip = { amount: '1.2500' }
    2.times { import }
    assert_equal 1, AuthorizeNetTransaction.count
    row = AuthorizeNetTransaction.first
    assert_equal BigDecimal('1.25'), row.tip_amount
    assert_nil row.surcharge_amount
    assert_equal 'USD', row.currency
    assert_equal 1, row.status_history.size
    @status = 'settledSuccessfully'
    @batch = true
    import
    row.reload
    assert_equal 'authCaptureTransaction', row.transaction_type
    assert_nil row.reference_transaction_id
    assert_equal '7001', row.source_batch_id
    assert_equal 'settledSuccessfully', row.settlement_state
    assert_equal 2, row.status_history.size
    assert_equal 1, AuthorizeNetBatch.count
    assert_equal '2.30', AuthorizeNetBatch.first.statistics.first['refundAmount']
    assert_equal 'complete', @connection.reload.last_report_status
  end

  test 'refund is a separate payment linked to the original and list membership preserves missing detail batch' do
    @batch = true
    @status = 'settledSuccessfully'
    stub_request(:post, @endpoint).with { |req| JSON.parse(req.body).key?('getTransactionListRequest') }
      .to_return(status: 200, body: success.merge(transactions: [{ transId: '9001' }, { transId: '9002' }], totalNumInResultSet: 2).to_json)
    stub_request(:post, @endpoint).with { |req| JSON.parse(req.body).dig('getTransactionDetailsRequest', 'transId') == '9002' }
      .to_return(status: 200, body: success.merge(transaction: detail.merge(transId: '9002', refTransId: '9001',
        transactionType: 'refundTransaction', transactionStatus: 'refundSettledSuccessfully', batch: nil)).to_json)
    import
    assert_equal 2, AuthorizeNetTransaction.count
    refund = AuthorizeNetTransaction.find_by!(source_transaction_id: '9002')
    assert_equal '9001', refund.reference_transaction_id
    assert_equal 'refundTransaction', refund.transaction_type
    assert_equal '7001', refund.source_batch_id
    assert_equal BigDecimal('2.3'), refund.settled_amount
    assert_equal 'settledSuccessfully', AuthorizeNetTransaction.find_by!(source_transaction_id: '9001').payment_status
  end

  test 'observed pending transaction is refreshed even when absent from both lists' do
    import
    @status = 'voided'
    @batch = true
    # Settled batch list and unsettled list both omit this transaction.
    stub_request(:post, @endpoint).with { |req| JSON.parse(req.body).key?('getTransactionListRequest') }
      .to_return(status: 200, body: success.merge(transactions: [], totalNumInResultSet: 0).to_json)
    import
    assert_equal 'voided', AuthorizeNetTransaction.first.payment_status
    assert_equal 1, AuthorizeNetTransaction.count
  end

  test 'allowlisted requests never use payment client, customer details or credential persistence' do
    AuthorizeNetClient.expects(:charge!).never
    import
    assert @calls.all? { |payload| AuthorizeNetReporting::Client::READ_METHODS.include?(payload.keys.first) }
    row = AuthorizeNetTransaction.first
    refute_includes row.attributes.to_json, 'CUSTOMER PRIVATE'
    raw = PosConnection.connection.select_value("SELECT credentials_json FROM pos_connections WHERE id = #{@connection.id}")
    refute_includes raw, 'synthetic-key'
    refute_includes raw, 'synthetic-report-login'
    assert_nil row.tip_amount
  end

  test 'same IDs in another environment stay separate' do
    import
    @connection.update!(environment: 'production')
    stub_request(:post, AuthorizeNetReporting::Client::ENDPOINTS.fetch('production')).to_return do |req|
      method = JSON.parse(req.body).keys.first
      data = case method
      when 'getMerchantDetailsRequest' then { gatewayId: '12345', currencies: ['USD'] }
      when 'getSettledBatchListRequest' then { batchList: [] }
      when 'getUnsettledTransactionListRequest' then { transactions: [{ transId: '9001' }], totalNumInResultSet: 1 }
      when 'getTransactionDetailsRequest' then { transaction: detail }
      end
      { status: 200, body: success.merge(data).to_json }
    end
    import
    assert_equal 2, AuthorizeNetTransaction.count
  end

  test 'other tenant cannot import or view this connection records' do
    import
    Current.tenant = Tenant.create!(name: 'Reporting isolation', subdomain: 'reporting-isolation', status: 'active')
    assert_equal 0, AuthorizeNetTransaction.count
    assert_raises(AuthorizeNetReporting::Client::Error) { import }
  end

  test 'gateway mismatch fails before fetching transaction lists' do
    @connection.update!(account_reference: '55555')
    assert_raises(AuthorizeNetReporting::Client::Error) { import }
    assert_equal 0, AuthorizeNetTransaction.count
    assert_equal ['getMerchantDetailsRequest'], @calls.map { |p| p.keys.first }
  end

  test 'detail failure leaves all batch and transaction records unchanged and error is sanitized' do
    @batch = true
    @detail_failure = true
    error = assert_raises(AuthorizeNetReporting::Client::Error) { import }
    refute_includes error.message, 'SECRET'
    assert_equal 0, AuthorizeNetBatch.count
    assert_equal 0, AuthorizeNetTransaction.count
    assert_nil @connection.reload.last_reported_at
  end

  test 'setup changed while fetching cannot save stale observations' do
    @on_detail = -> { PosConnection.find(@connection.id).update!(account_reference: '55555') }
    assert_raises(AuthorizeNetReporting::Client::Error) { import }
    assert_equal 0, AuthorizeNetTransaction.count
  end

  test 'currency is unknown for a multicurrency merchant, never guessed USD' do
    @currencies = ['USD', 'CAD']
    import
    assert_nil AuthorizeNetTransaction.first.currency
  end

  test 'incomplete pages and invalid monetary values fail atomically' do
    @total_override = 2
    assert_raises(AuthorizeNetReporting::Client::Error) { import }
    @total_override = nil
    @tip = { amount: 'NaN' }
    assert_raises(AuthorizeNetReporting::Client::Error) { import }
    assert_equal 0, AuthorizeNetTransaction.count
  end

  test 'pagination uses page offsets beyond 1000 and rejects repeated pages' do
    client = AuthorizeNetReporting::Client.new(@connection)
    pages = [success.merge('transactions' => (1..1000).map { |i| { 'transId' => i.to_s } }, 'totalNumInResultSet' => 1001),
      success.merge('transactions' => [{ 'transId' => '1001' }], 'totalNumInResultSet' => 0)]
    offsets = []
    stub_request(:post, @endpoint).to_return do |req|
      offsets << JSON.parse(req.body).dig('getUnsettledTransactionListRequest', 'paging', 'offset')
      { status: 200, body: pages.shift.to_json }
    end
    assert_equal 1001, client.transactions.size
    assert_equal [1, 2], offsets
    stub_request(:post, @endpoint).to_return(status: 200,
      body: success.merge(transactions: (1..1000).map { |i| { transId: i.to_s } }, totalNumInResultSet: 2000).to_json)
    assert_raises(AuthorizeNetReporting::Client::Error) { client.transactions }
  end

  test 'unknown environment, payment methods, oversized responses and redirects are rejected' do
    client = AuthorizeNetReporting::Client.new(@connection)
    assert_raises(AuthorizeNetReporting::Client::Error) { client.request('createTransactionRequest') }
    assert_raises(AuthorizeNetReporting::Client::Error) { client.request('getMerchantDetailsRequest', merchantAuthentication: {}) }
    @connection.environment = 'unknown'
    assert_raises(AuthorizeNetReporting::Client::Error) { AuthorizeNetReporting::Client.new(@connection) }
    stub_request(:post, @endpoint).to_return(status: 302, headers: { 'Location' => 'https://attacker.invalid' })
    assert_raises(AuthorizeNetReporting::Client::Error) { client.merchant }
    stub_request(:post, @endpoint).to_return(status: 200, headers: { 'Content-Length' => (AuthorizeNetReporting::Client::MAX_BYTES + 1).to_s })
    assert_raises(AuthorizeNetReporting::Client::Error) { client.merchant }
  end

  test 'BOM works and fixed network errors do not expose exception contents' do
    client = AuthorizeNetReporting::Client.new(@connection)
    stub_request(:post, @endpoint).to_return(status: 200, body: "\xEF\xBB\xBF" + success.merge(gatewayId: '12345').to_json)
    assert_equal '12345', client.merchant['gatewayId']
    stub_request(:post, @endpoint).to_raise(SocketError.new('SECRET in exception'))
    error = assert_raises(AuthorizeNetReporting::Client::Error) { client.merchant }
    refute_includes error.message, 'SECRET'
  end

  test 'date range validates before batch request' do
    client = AuthorizeNetReporting::Client.new(@connection)
    assert_raises(AuthorizeNetReporting::Client::Error) { client.batches(from: 32.days.ago, to: Time.current) }
    assert_raises(AuthorizeNetReporting::Client::Error) { client.batches(from: Time.current, to: 1.day.ago) }
    assert_empty @calls
  end

  test 'OAuth refresh enforces read scope and stores rotated refresh token encrypted' do
    @connection.apply_setup({ reporting_auth_mode: 'oauth' }, { client_id: 'synthetic-client', client_secret: 'synthetic-secret', refresh_token: 'synthetic-refresh' })
    @connection.save!
    url = AuthorizeNetReporting::Client::TOKEN_ENDPOINTS.fetch('sandbox')
    stub_request(:post, url).with(body: { grant_type: 'refresh_token', client_id: 'synthetic-client', client_secret: 'synthetic-secret', refresh_token: 'synthetic-refresh' })
      .to_return(status: 200, body: { access_token: 'synthetic-access', refresh_token: 'rotated-refresh', scope: 'read' }.to_json)
    import
    assert @calls.all? { |payload| payload.values.first['merchantAuthentication'] == { 'accessToken' => 'synthetic-access' } }
    assert_equal 'rotated-refresh', @connection.reload.credential_values['refresh_token']
    refute_includes @connection.attributes.to_json, 'synthetic-access'
    stub_request(:post, url).to_return(status: 200, body: { access_token: 'broad-access', scope: 'read write' }.to_json)
    assert_raises(AuthorizeNetReporting::Client::Error) { import }
  end

  test 'diagnostics verify actual reporting methods and state unavailable probes precisely' do
    result = AuthorizeNetReporting::Check.call(connection: @connection)
    assert_equal 'verified', result[:status]
    assert_includes result[:message], 'No batch was available'
    assert_includes result[:message], 'transaction detail was also read'
    assert_equal 0, AuthorizeNetTransaction.count
    @batch = true
    result = AuthorizeNetReporting::Check.call(connection: @connection)
    assert_equal 'verified', result[:status]
    assert_includes result[:message], 'Settled transaction list access checked'
    @detail_failure = true
    assert_equal 'failed', AuthorizeNetReporting::Check.call(connection: @connection)[:status]
  end

  test 'queued manual import does not run after setup changes or disconnect' do
    old_version = @connection.lock_version
    @connection.update!(account_reference: '55555')
    AuthorizeNetReporting::Import.expects(:call).never
    AuthorizeNetReportingJob.perform_now(tenant_id: @connection.tenant_id, connection_id: @connection.id, setup_version: old_version)
  end

  test 'scheduler is opt in and records sanitized failure without importing' do
    AuthorizeNetReporting::Import.expects(:call).never
    AuthorizeNetReportingJob.perform_now
    @connection.update!(reporting_enabled: true)
    @detail_failure = true
    # Remove the never expectation for the enabled execution.
    AuthorizeNetReporting::Import.unstub(:call)
    AuthorizeNetReportingJob.perform_now
    assert_equal 'failed', @connection.reload.last_report_status
    refute_includes @connection.last_report_message, 'SECRET'
    assert_nil @connection.last_reported_at
  end

  private

  def import
    AuthorizeNetReporting::Import.call(connection: @connection)
  end

  def success
    { 'messages' => { 'resultCode' => 'Ok', 'message' => [{ 'code' => 'I00001', 'text' => 'Successful.' }] } }
  end

  def batch
    { batchId: '7001', settlementTimeUTC: '2026-10-15T05:00:00Z', settlementState: 'settledSuccessfully',
      paymentMethod: 'creditCard', statistics: [{ accountType: 'Visa', refundAmount: '2.30', refundCount: 1 }] }
  end

  def detail
    { transId: '9001', refTransId: @status.start_with?('refund') ? '8999' : nil,
      submitTimeUTC: '2026-10-14T18:00:00', transactionType: @status.start_with?('refund') ? 'refundTransaction' : 'authCaptureTransaction',
      transactionStatus: @status, authAmount: '2.3000', settleAmount: '2.3000', tip: @tip,
      batch: @batch ? batch.except(:statistics) : nil, customer: { email: 'CUSTOMER PRIVATE' } }
  end
end
