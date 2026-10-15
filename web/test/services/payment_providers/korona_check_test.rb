# frozen_string_literal: true

require 'test_helper'

class PaymentProviders::KoronaCheckTest < ActiveSupport::TestCase
  setup do
    @credentials = {
      'api_url' => 'https://167.koronacloud.com/web/api/v3',
      'account_id' => '12345678-1234-1234-1234-123456789abc',
      'api_username' => 'dedicated-api-user',
      'api_password' => 'private-api-password'
    }
    @endpoint = "#{@credentials['api_url']}/accounts/#{@credentials['account_id']}/organizationalUnits?page=1&size=1"
  end

  test 'checks only the first bounded organizational unit page with basic authentication' do
    request = stub_check(body: page_json)
    result = check

    assert_equal 'verified', result[:status]
    assert_includes result[:message], 'Payments and terminals are not enabled'
    assert_equal [:message, :status], result.keys.sort
    assert_requested request, times: 1
    refute_includes result.to_json, 'Private shop name'
    refute_includes result.to_json, @credentials['api_password']
  end

  test 'accepts documented empty collection and www endpoint' do
    @credentials['api_url'] = 'https://www.koronacloud.com/web/api/v3'
    url = @endpoint.sub('167.', 'www.')
    stub_request(:get, url).to_return(status: 200, body: page_json(results: []))

    assert_equal 'verified', check[:status]
  end

  test '401 and 403 produce fixed safe messages without exposing remote bodies' do
    { 401 => 'rejected the API credentials', 403 => 'denied organizational-unit read access' }.each do |status, text|
      stub_check(status: status, body: 'Private account or password details')
      result = check
      assert_equal 'failed', result[:status]
      assert_includes result[:message], text
      refute_includes result.to_json, 'Private account'
    end
  end

  test 'rejects custom hosts and any endpoint variation before making a request' do
    [
      'http://167.koronacloud.com/web/api/v3',
      'https://koronacloud.com/web/api/v3',
      'https://evil.example/web/api/v3',
      'https://167.koronacloud.com.evil.example/web/api/v3',
      'https://foo.koronacloud.com/web/api/v3',
      'https://user:password@167.koronacloud.com/web/api/v3',
      'https://167.koronacloud.com:443/web/api/v3',
      'https://167.koronacloud.com:8443/web/api/v3',
      'https://167.koronacloud.com/web/api/v3/',
      'https://167.koronacloud.com/web/api/v3?next=elsewhere',
      'https://167.koronacloud.com/web/api/v3#fragment',
      'https://167.koronacloud.com/web/api/v3/../customers',
      'https://127.0.0.1/web/api/v3'
    ].each do |url|
      @credentials['api_url'] = url
      assert_equal 'failed', check[:status], url
    end
    assert_not_requested(:any, /./)
  end

  test 'rejects invalid account identifiers and missing or malformed credentials locally' do
    ['not-a-uuid', '../customers', '12345678-1234-1234-1234-123456789abc?size=500'].each do |account|
      assert_equal 'failed', check(@credentials.merge('account_id' => account))[:status]
    end
    ['api_url', 'account_id', 'api_username', 'api_password'].each do |key|
      assert_equal 'failed', check(@credentials.except(key))[:status]
    end
    assert_equal 'failed', check(nil)[:status]
    assert_equal 'failed', check(@credentials.merge('api_username' => 'user:other'))[:status]
    assert_equal 'failed', check(@credentials.merge('api_password' => "password\nheader"))[:status]
    assert_not_requested(:any, /./)
  end

  test 'never follows a redirect or forwards credentials to another server' do
    request = stub_check(status: 302, body: '', headers: { 'Location' => 'https://evil.example/collect' })

    assert_equal 'failed', check[:status]
    assert_requested request, times: 1
    assert_not_requested(:any, 'https://evil.example/collect')
  end

  test 'network timeouts are sanitized and not retried' do
    request = stub_request(:get, @endpoint).to_timeout

    result = check
    assert_equal 'failed', result[:status]
    assert_includes result[:message], 'could not be reached securely'
    assert_requested request, times: 1
  end

  test 'TLS failures never expose the exception or credentials' do
    stub_request(:get, @endpoint).to_raise(OpenSSL::SSL::SSLError.new('private-api-password certificate details'))

    result = check
    assert_equal 'failed', result[:status]
    refute_includes result.to_json, 'private-api-password'
    refute_includes result.to_json, 'certificate details'
  end

  test 'rejects malformed JSON and unexpected collection envelopes' do
    [
      '<html>Sign in</html>', '{not-json', 'null', '[]', '{}',
      page_json(current_page: 2),
      { currentPage: 1, results: ['unexpected'], resultsOfPage: 1, resultsTotal: 1 }.to_json,
      { currentPage: 1, results: [], resultsOfPage: 0, resultsTotal: '0' }.to_json,
      { currentPage: 1, results: [], resultsOfPage: 1, resultsTotal: 1 }.to_json,
      page_json(results: [{ id: 'one' }, { id: 'two' }])
    ].each do |body|
      stub_check(body: body)
      assert_equal 'failed', check[:status], body
    end
  end

  test 'rejects oversized declared and undeclared response bodies' do
    oversized = 'x' * (PaymentProviders::KoronaCheck::MAX_RESPONSE_BYTES + 1)
    stub_check(body: oversized)
    assert_equal 'failed', check[:status]

    stub_check(body: page_json, headers: { 'Content-Length' => oversized.bytesize.to_s })
    assert_equal 'failed', check[:status]
  end

  test 'accepts the documented 204 empty collection response' do
    stub_check(status: 204, body: '')
    assert_equal 'verified', check[:status]
  end

  test 'does not expose server errors or accept undocumented success responses' do
    stub_check(status: 202, body: page_json)
    assert_equal 'failed', check[:status]
    stub_check(status: 500, body: 'private server diagnostics')
    result = check
    assert_equal 'failed', result[:status]
    refute_includes result.to_json, 'private server diagnostics'
  end

  private

  def check(credentials = @credentials)
    PaymentProviders::KoronaCheck.call(credentials: credentials)
  end

  def stub_check(status: 200, body: page_json, headers: {})
    stub_request(:get, @endpoint)
      .with(basic_auth: [@credentials['api_username'], @credentials['api_password']],
        headers: { 'Accept' => 'application/json', 'Accept-Encoding' => 'identity' })
      .to_return(status: status, body: body, headers: headers)
  end

  def page_json(results: [{ id: '87654321-4321-4321-4321-cba987654321', name: 'Private shop name' }], current_page: 1)
    {
      currentPage: current_page, results: results, resultsOfPage: results.length,
      resultsTotal: results.length, pagesTotal: results.empty? ? 0 : 1, links: {}
    }.to_json
  end
end
