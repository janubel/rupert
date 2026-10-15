# frozen_string_literal: true

require 'test_helper'

class PaymentProviders::AuthorizeNetCheckTest < ActiveSupport::TestCase
  setup do
    @credentials = { 'api_login_id' => 'dedicated-api-login', 'transaction_key' => '1234567890ABCDEF' }
    @sandbox_url = 'https://apitest.authorize.net/xml/v1/request.api'
    @production_url = 'https://api.authorize.net/xml/v1/request.api'
  end

  test 'sandbox checks authentication only with the exact documented payload' do
    request = stub_check
    result = check

    assert_equal 'verified', result[:status]
    assert_includes result[:message], 'Payment processing and terminals are not enabled'
    assert_equal [:message, :status], result.keys.sort
    assert_requested request, times: 1
    assert_not_requested(:any, @production_url)
    refute_includes result.to_json, @credentials['transaction_key']
    refute_includes result.to_json, 'private-session-token'
  end

  test 'production uses only the fixed production endpoint' do
    request = stub_check(environment: 'production')

    assert_equal 'verified', check(environment: 'production')[:status]
    assert_requested request, times: 1
    assert_not_requested(:any, @sandbox_url)
  end

  test 'unknown environments never default to production or send credentials' do
    ['live', 'test', '', nil, :production, 'https://evil.example/collect'].each do |environment|
      assert_equal 'failed', check(environment: environment)[:status]
    end
    assert_not_requested(:any, /./)
  end

  test 'invalid or missing API credentials fail locally' do
    [nil, {}, @credentials.except('api_login_id'), @credentials.except('transaction_key'),
     @credentials.merge('api_login_id' => 'x' * 21), @credentials.merge('transaction_key' => 'x' * 17),
     @credentials.merge('api_login_id' => ' '), @credentials.merge('transaction_key' => "key\nheader"),
     @credentials.merge('transaction_key' => 123)].each do |credentials|
      assert_equal 'failed', check(credentials: credentials)[:status]
    end
    assert_not_requested(:any, /./)
  end

  test 'accepts the documented optional UTF8 BOM but ignores provider session data' do
    stub_check(body: "\xEF\xBB\xBF".b + success_json.b)

    result = check
    assert_equal 'verified', result[:status]
    refute_includes result.to_json, 'private-session-token'
  end

  test 'gateway credential errors return a fixed safe message' do
    stub_check(body: {
      messages: { resultCode: 'Error', message: [{ code: 'E00007', text: 'Private merchant credentials invalid' }] }
    }.to_json)

    result = check
    assert_equal 'failed', result[:status]
    assert_includes result[:message], 'did not verify the API credentials'
    refute_includes result.to_json, 'Private merchant'
    refute_includes result.to_json, 'E00007'
  end

  test 'HTTP credential failures do not expose response bodies' do
    [401, 403].each do |status|
      stub_check(status: status, body: 'private account details')
      result = check
      assert_equal 'failed', result[:status]
      assert_includes result[:message], 'did not verify the API credentials'
      refute_includes result.to_json, 'private account'
    end
  end

  test 'only expected I00001 success messages verify credentials' do
    [
      { messages: { resultCode: 'Ok', message: [] } },
      { messages: { resultCode: 'Ok', message: [{ code: 'I99999' }] } },
      { messages: { resultCode: 'Ok', message: [{ code: 'I00001' }, { code: 'E00007' }] } },
      { messages: { resultCode: 'Ok', message: { code: 'I00001' } } },
      { messages: { resultCode: 'Other', message: [{ code: 'I00001' }] } },
      { messages: { resultCode: 'Ok', message: [123] } }
    ].each do |body|
      stub_check(body: body.to_json)
      assert_equal 'failed', check[:status]
    end
  end

  test 'malformed HTML JSON encoding and unexpected envelopes are sanitized' do
    ['<html>Private details</html>', '{invalid', '[]', '{}', 'null',
     { messages: [] }.to_json, "\xFF".b + success_json.b].each do |body|
      stub_check(body: body)
      result = check
      assert_equal 'failed', result[:status]
      refute_includes result.to_json, 'Private details'
    end
  end

  test 'redirects never forward merchant credentials to another endpoint' do
    request = stub_check(status: 302, body: '', headers: { 'Location' => 'https://evil.example/collect' })

    assert_equal 'failed', check[:status]
    assert_requested request, times: 1
    assert_not_requested(:any, 'https://evil.example/collect')
  end

  test 'bounds both streamed and declared response sizes' do
    oversized = 'x' * (PaymentProviders::AuthorizeNetCheck::MAX_RESPONSE_BYTES + 1)
    stub_check(body: oversized)
    assert_equal 'failed', check[:status]
    stub_check(headers: { 'Content-Length' => oversized.bytesize.to_s })
    assert_equal 'failed', check[:status]
  end

  test 'timeouts are not retried and TLS failures do not expose exception details' do
    request = stub_request(:post, @sandbox_url).to_timeout
    result = check
    assert_equal 'failed', result[:status]
    assert_includes result[:message], 'could not be reached securely'
    assert_requested request, times: 1

    stub_request(:post, @sandbox_url).to_raise(OpenSSL::SSL::SSLError.new('1234567890ABCDEF private certificate'))
    result = check
    assert_equal 'failed', result[:status]
    refute_includes result.to_json, @credentials['transaction_key']
    refute_includes result.to_json, 'private certificate'
  end

  test 'server and undocumented success statuses fail without exposing diagnostics' do
    [500, 204, 202].each do |status|
      stub_check(status: status, body: 'private server diagnostics')
      result = check
      assert_equal 'failed', result[:status]
      refute_includes result.to_json, 'private server diagnostics'
    end
  end

  private

  def check(credentials: @credentials, environment: 'sandbox')
    PaymentProviders::AuthorizeNetCheck.call(credentials: credentials, environment: environment)
  end

  def success_json
    {
      messages: { resultCode: 'Ok', message: [{ code: 'I00001', text: 'Successful.' }] },
      sessionToken: 'private-session-token'
    }.to_json
  end

  def stub_check(environment: 'sandbox', status: 200, body: success_json, headers: {})
    endpoint = environment == 'production' ? @production_url : @sandbox_url
    payload = JSON.generate(authenticateTestRequest: {
      merchantAuthentication: { name: @credentials['api_login_id'], transactionKey: @credentials['transaction_key'] }
    })
    stub_request(:post, endpoint)
      .with(body: payload, headers: {
        'Content-Type' => 'application/json', 'Accept' => 'application/json', 'Accept-Encoding' => 'identity'
      })
      .to_return(status: status, body: body, headers: headers)
  end
end
