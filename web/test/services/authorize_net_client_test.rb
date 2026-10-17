# frozen_string_literal: true

require 'test_helper'

class AuthorizeNetClientTest < ActiveSupport::TestCase
  setup do
    @tenant = Tenant.create!(name: 'Auth Co', subdomain: 'authco')
    Current.tenant = @tenant
    EnvStore.set('AUTHORIZE_NET_LOGIN_ID', 'testlogin')
    EnvStore.set('AUTHORIZE_NET_TRANSACTION_KEY', 'testtxnkey')
    EnvStore.set('AUTHORIZE_NET_SANDBOX', '1')
  end

  teardown do
    EnvStore.set('AUTHORIZE_NET_LOGIN_ID', nil)
    EnvStore.set('AUTHORIZE_NET_TRANSACTION_KEY', nil)
    EnvStore.set('AUTHORIZE_NET_SANDBOX', nil)
    Current.tenant = nil
  end

  def gateway_body(response_code:, trans_id: '4000', message: 'This transaction has been approved.')
    {
      transactionResponse: {
        responseCode: response_code,
        transId: trans_id,
        authCode: response_code == '1' ? 'OK' : nil,
        messages: { code: response_code, description: message }
      }
    }.to_json
  end

  test 'charge is approved for responseCode 1' do
    stub_request(:post, 'https://apitest.authorize.net/xml/v1/request.api')
      .to_return(status: 200, body: gateway_body(response_code: '1'), headers: { 'Content-Type' => 'application/json' })

    result = AuthorizeNetClient.charge!(amount_cents: 1000, payment_nonce: 'nonce-1', ref_id: 'r1',
      invoice_number: 'WH-1')

    assert result.approved?
    assert_equal '4000', result.transaction_id
    assert_equal 'OK', result.auth_code
  end

  test 'charge is declined for other response codes' do
    stub_request(:post, 'https://apitest.authorize.net/xml/v1/request.api')
      .to_return(status: 200,
        body: gateway_body(response_code: '2', message: 'This transaction has been declined.'),
        headers: { 'Content-Type' => 'application/json' })

    result = AuthorizeNetClient.charge!(amount_cents: 1000, payment_nonce: 'bad-nonce')

    refute result.approved?
    assert_equal '2', result.response_code
    assert_includes result.message, 'declined'
  end

  test 'gateway error surfaces as a message' do
    stub_request(:post, 'https://apitest.authorize.net/xml/v1/request.api')
      .to_return(status: 200,
        body: { messages: { resultCode: 'Error',
                            message: [{ code: 'E00003', text: 'Invalid credentials' }] } }.to_json,
        headers: { 'Content-Type' => 'application/json' })

    result = AuthorizeNetClient.charge!(amount_cents: 100, payment_nonce: 'nonce')

    refute result.approved?
    assert_includes result.message, 'Invalid credentials'
  end

  test 'raises when not configured' do
    EnvStore.set('AUTHORIZE_NET_LOGIN_ID', nil)
    EnvStore.set('AUTHORIZE_NET_TRANSACTION_KEY', nil)

    assert_raises(AuthorizeNetClient::Error) do
      AuthorizeNetClient.charge!(amount_cents: 100, payment_nonce: 'nonce')
    end
  end

  ENDPOINT = 'https://apitest.authorize.net/xml/v1/request.api'

  test 'void sends voidTransaction with the original id and no amount or card' do
    request = stub_request(:post, ENDPOINT).with { |req|
      body = JSON.parse(req.body).fetch('createTransactionRequest').fetch('transactionRequest')
      body == { 'transactionType' => 'voidTransaction', 'refTransId' => '4000' }
    }.to_return(status: 200, body: gateway_body(response_code: '1', trans_id: '4001'))

    result = AuthorizeNetClient.void!(transaction_id: '4000')

    assert_requested request
    assert result.approved?
  end

  test 'refund sends refundTransaction with last four only' do
    request = stub_request(:post, ENDPOINT).with { |req|
      body = JSON.parse(req.body).fetch('createTransactionRequest').fetch('transactionRequest')
      body['transactionType'] == 'refundTransaction' && body['refTransId'] == '4000' &&
        body['amount'] == '12.34' &&
        body['payment'] == { 'creditCard' => { 'cardNumber' => '1111', 'expirationDate' => 'XXXX' } }
    }.to_return(status: 200, body: gateway_body(response_code: '1', trans_id: '4002'))

    result = AuthorizeNetClient.refund!(transaction_id: '4000', amount_cents: 1234, last_four: '1111')

    assert_requested request
    assert result.approved?
  end

  test 'refund rejects anything but four digits so a full card number is never sent' do
    assert_raises(AuthorizeNetClient::Error) do
      AuthorizeNetClient.refund!(transaction_id: '4000', amount_cents: 100, last_four: '4111111111111111')
    end
    assert_not_requested :post, ENDPOINT
  end

  test 'transaction_details returns status and last four' do
    stub_request(:post, ENDPOINT).to_return(status: 200, body: {
      transaction: { transactionStatus: 'settledSuccessfully', authAmount: 12.34,
                     payment: { creditCard: { cardNumber: 'XXXX1111' } } },
      messages: { resultCode: 'Ok' }
    }.to_json)

    details = AuthorizeNetClient.transaction_details('4000')

    assert_equal 'settledSuccessfully', details[:status]
    assert_equal '1111', details[:last_four]
  end

  test 'transaction_details raises the gateway error' do
    stub_request(:post, ENDPOINT).to_return(status: 200, body: {
      messages: { resultCode: 'Error', message: [{ code: 'E00040', text: 'The record cannot be found.' }] }
    }.to_json)

    error = assert_raises(AuthorizeNetClient::Error) { AuthorizeNetClient.transaction_details('nope') }
    assert_includes error.message, 'cannot be found'
  end

  test 'valmar authorize.net connection overrides legacy settings and sets environment' do
    connection = PosConnection.new(provider: 'valmar')
    connection.apply_setup({ 'gateway' => 'authorize_net', 'environment' => 'production', 'vendor_approved' => true },
      { 'api_login_id' => 'connlogin', 'transaction_key' => 'conntxnkey', 'client_key' => 'connclient' })
    connection.save!

    assert_equal 'connlogin', AuthorizeNetClient.login_id
    assert_equal 'conntxnkey', AuthorizeNetClient.transaction_key
    assert_equal 'connclient', AuthorizeNetClient.client_key
    refute AuthorizeNetClient.sandbox?
    assert_equal 'https://js.authorize.net/v1/Accept.js', AuthorizeNetClient.accept_js_url

    request = stub_request(:post, 'https://api.authorize.net/xml/v1/request.api').with { |req|
      auth = JSON.parse(req.body).dig('createTransactionRequest', 'merchantAuthentication')
      auth == { 'name' => 'connlogin', 'transactionKey' => 'conntxnkey' }
    }.to_return(status: 200, body: gateway_body(response_code: '1'))
    assert AuthorizeNetClient.charge!(amount_cents: 500, payment_nonce: 'n').approved?
    assert_requested request
  end

  test 'non-authorize.net connection falls back to legacy settings' do
    connection = PosConnection.new(provider: 'valmar')
    connection.apply_setup({ 'gateway' => 'nmi', 'environment' => 'production', 'vendor_approved' => true },
      { 'security_key' => 'nmi-key' })
    connection.save!

    assert_equal 'testlogin', AuthorizeNetClient.login_id
    assert AuthorizeNetClient.sandbox?
  end

  test 'connection credentials never leak across tenants' do
    connection = PosConnection.new(provider: 'valmar')
    connection.apply_setup({ 'gateway' => 'authorize_net', 'environment' => 'production', 'vendor_approved' => true },
      { 'api_login_id' => 'connlogin', 'transaction_key' => 'conntxnkey', 'client_key' => 'connclient' })
    connection.save!

    Current.tenant = Tenant.create!(name: 'Other Co', subdomain: 'otherco')
    refute_equal 'connlogin', AuthorizeNetClient.login_id
  end
  test 'saved payment credentials never mix with legacy credentials' do
    connection = Struct.new(:credential_values, :environment).new({ 'api_login_id' => 'saved-login' }, 'production')
    AuthorizeNetClient.stubs(:saved_connection).returns(connection)
    assert_equal 'saved-login', AuthorizeNetClient.login_id
    assert_equal '', AuthorizeNetClient.transaction_key
    assert_equal '', AuthorizeNetClient.client_key
    assert_not AuthorizeNetClient.configured?
    assert_not AuthorizeNetClient.sandbox?
    assert_raises(AuthorizeNetClient::Error) { AuthorizeNetClient.charge!(amount_cents: 100, payment_nonce: 'nonce') }
    assert_not_requested :post, ENDPOINT
  end
end
