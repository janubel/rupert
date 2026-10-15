# frozen_string_literal: true

require 'test_helper'

class PaymentProviders::CovaCheckTest < ActiveSupport::TestCase
  setup do
    @credentials = {
      'company_id' => '1234', 'client_id' => 'approved-client', 'client_secret' => 'private-client-secret',
      'api_username' => 'dedicated-api-user', 'api_password' => 'private-api-password'
    }
    @locations_url = 'https://api.covasoft.net/entitymanager/v1/Companies(1234)/Locations'
    @bearer_token = 'temporary-private-bearer.token'
  end

  test 'exchanges onboarding credentials then checks company locations only' do
    auth = stub_auth
    read = stub_locations(body: [{ Id: 7, Name: 'Private location', Address: { Email: 'private@example.invalid' } }].to_json)

    result = check
    assert_equal 'verified', result[:status]
    assert_includes result[:message], 'Payments and terminals are not enabled'
    assert_equal [:message, :status], result.keys.sort
    assert_requested auth, times: 1
    assert_requested read, times: 1
    ['Private location', 'private@example.invalid', @bearer_token, 'private-refresh-token',
     @credentials['client_secret'], @credentials['api_password']].each do |secret|
      refute_includes result.to_json, secret
    end
  end

  test 'empty location array is a successful authorized read' do
    stub_auth
    stub_locations(body: '[]')

    assert_equal 'verified', check[:status]
  end

  test 'invalid or missing company identifiers and credentials cause no network requests' do
    ['0', '-1', '1234/Customers', '1)evil', '2147483648', ' 1 ', '1.0', nil].each do |id|
      assert_equal 'failed', check(@credentials.merge('company_id' => id))[:status]
    end
    ['client_id', 'client_secret', 'api_username', 'api_password'].each do |key|
      assert_equal 'failed', check(@credentials.except(key))[:status]
    end
    assert_equal 'failed', check(nil)[:status]
    assert_equal 'failed', check(@credentials.merge('api_password' => "password\nheader"))[:status]
    assert_not_requested(:any, /./)
  end

  test 'OAuth errors are fixed and do not attempt a location read' do
    [400, 401, 403, 500].each do |status|
      stub_auth(status: status, body: 'private authentication diagnostics')
      result = check
      assert_equal 'failed', result[:status]
      refute_includes result.to_json, 'private authentication diagnostics'
    end
    assert_not_requested(:get, @locations_url)
  end

  test 'location permissions failures return fixed messages' do
    stub_auth
    { 401 => 'rejected the API credentials', 403 => 'denied company-location read access' }.each do |status, text|
      stub_locations(status: status, body: 'private merchant account details')
      result = check
      assert_equal 'failed', result[:status]
      assert_includes result[:message], text
      refute_includes result.to_json, 'private merchant'
    end
  end

  test 'OAuth redirect does not forward onboarding credentials or attempt a read' do
    request = stub_auth(status: 302, body: '', headers: { 'Location' => 'https://evil.example/collect' })

    assert_equal 'failed', check[:status]
    assert_requested request, times: 1
    assert_not_requested(:any, 'https://evil.example/collect')
    assert_not_requested(:get, @locations_url)
  end

  test 'location redirect never forwards the bearer token to another host' do
    stub_auth
    request = stub_locations(status: 302, body: '', headers: { 'Location' => 'https://evil.example/collect' })

    assert_equal 'failed', check[:status]
    assert_requested request, times: 1
    assert_not_requested(:any, 'https://evil.example/collect')
  end

  test 'OAuth timeout is sanitized and not retried' do
    request = stub_request(:post, PaymentProviders::CovaCheck::TOKEN_URL).to_timeout

    result = check
    assert_equal 'failed', result[:status]
    assert_includes result[:message], 'could not be reached securely'
    assert_requested request, times: 1
    assert_not_requested(:get, @locations_url)
  end

  test 'location timeout and TLS errors are sanitized and not retried' do
    stub_auth
    request = stub_request(:get, @locations_url).to_timeout
    assert_equal 'failed', check[:status]
    assert_requested request, times: 1

    stub_request(:get, @locations_url).to_raise(OpenSSL::SSL::SSLError.new('private token or certificate details'))
    result = check
    assert_equal 'failed', result[:status]
    refute_includes result.to_json, 'private token'
  end

  test 'malformed authentication responses never produce a bearer request' do
    ['<html>Sign in</html>', '{invalid', '[]', '{}', 'null',
     { access_token: 123 }.to_json, { access_token: "bad\nheader" }.to_json,
     { access_token: 'x' * 8193 }.to_json].each do |body|
      stub_auth(body: body)
      assert_equal 'failed', check[:status]
    end
    assert_not_requested(:get, @locations_url)
  end

  test 'malformed location responses fail without returning provider data' do
    stub_auth
    ['<html>Private data</html>', '{invalid', '{}', 'null', '["private"]',
     [{ Name: 'missing ID' }].to_json, [{ Id: 0 }].to_json].each do |body|
      stub_locations(body: body)
      result = check
      assert_equal 'failed', result[:status]
      refute_includes result.to_json, 'Private data'
    end
  end

  test 'bounds token and location bodies by both streamed size and declared length' do
    oversized = 'x' * (PaymentProviders::CovaCheck::MAX_RESPONSE_BYTES + 1)
    stub_auth(body: oversized)
    assert_equal 'failed', check[:status]
    stub_auth(headers: { 'Content-Length' => oversized.bytesize.to_s })
    assert_equal 'failed', check[:status]

    stub_auth
    stub_locations(body: oversized)
    assert_equal 'failed', check[:status]
    stub_locations(body: '[]', headers: { 'Content-Length' => oversized.bytesize.to_s })
    assert_equal 'failed', check[:status]
  end

  private

  def check(credentials = @credentials)
    PaymentProviders::CovaCheck.call(credentials: credentials)
  end

  def stub_auth(status: 200, body: nil, headers: {})
    stub_request(:post, PaymentProviders::CovaCheck::TOKEN_URL)
      .with(body: {
        'grant_type' => 'password', 'username' => @credentials['api_username'],
        'password' => @credentials['api_password'], 'client_id' => @credentials['client_id'],
        'client_secret' => @credentials['client_secret']
      }, headers: { 'Content-Type' => 'application/x-www-form-urlencoded' })
      .to_return(status: status,
        body: body || { access_token: @bearer_token, refresh_token: 'private-refresh-token' }.to_json,
        headers: headers)
  end

  def stub_locations(status: 200, body: '[]', headers: {})
    stub_request(:get, @locations_url)
      .with(headers: { 'Authorization' => "Bearer #{@bearer_token}", 'Accept' => 'application/json' })
      .to_return(status: status, body: body, headers: headers)
  end
end
