# frozen_string_literal: true

require 'test_helper'

class PaymentProviders::NmiCheckTest < ActiveSupport::TestCase
  setup do
    @credentials = { 'security_key' => 'dedicated-private-merchant-api-key' }
    @sandbox_url = 'https://sandbox.nmi.com/api/query.php'
    @production_url = 'https://secure.nmi.com/api/query.php'
  end

  test 'sandbox posts only security key and explicit profile report type' do
    request = stub_check
    result = check

    assert_equal 'verified', result[:status]
    assert_includes result[:message], 'Payment processing and terminals are not enabled'
    assert_equal [:message, :status], result.keys.sort
    assert_requested request, times: 1
    assert_not_requested(:any, @production_url)
    assert_not_requested(:any, %r{/transact\.php})
    ['Private merchant', 'private@example.invalid', @credentials['security_key']].each do |private_value|
      refute_includes result.to_json, private_value
    end
  end

  test 'production profile check uses only the fixed secure NMI Query endpoint' do
    request = stub_check(environment: 'production')

    assert_equal 'verified', check(environment: 'production')[:status]
    assert_requested request, times: 1
    assert_not_requested(:any, @sandbox_url)
  end

  test 'unknown environments never send merchant credentials' do
    ['live', 'test', '', nil, :production, 'https://evil.example/collect'].each do |environment|
      assert_equal 'failed', check(environment: environment)[:status]
    end
    assert_not_requested(:any, /./)
  end

  test 'missing malformed or oversized credentials fail locally' do
    [nil, {}, { 'security_key' => nil }, { 'security_key' => 123 }, { 'security_key' => ' ' },
     { 'security_key' => "key\nheader" }, { 'security_key' => 'x' * 4097 }].each do |credentials|
      assert_equal 'failed', check(credentials: credentials)[:status]
    end
    assert_not_requested(:any, /./)
  end

  test 'authentication error XML fails closed without exposing vendor diagnostics' do
    stub_check(body: '<nm_response><error>Private authentication error</error></nm_response>')

    result = check
    assert_equal 'failed', result[:status]
    refute_includes result.to_json, 'Private authentication'
  end

  test 'missing empty duplicate or wrong profile elements never verify access' do
    [
      '<nm_response/>', '<nm_response><merchant/></nm_response>',
      '<nm_response><merchant><company> </company></merchant></nm_response>',
      '<nm_response><gateway><company>Gateway only</company></gateway></nm_response>',
      '<different><merchant><company>Unknown</company></merchant></different>',
      '<nm_response><merchant><company>One</company><company>Two</company></merchant></nm_response>',
      '<nm_response><merchant><company>One</company></merchant><merchant><company>Two</company></merchant></nm_response>',
      '<nm_response><merchant><company><nested>Unexpected</nested></company></merchant></nm_response>',
      '<nm_response xmlns="https://evil.example"><merchant><company>Unknown</company></merchant></nm_response>'
    ].each do |body|
      stub_check(body: body)
      assert_equal 'failed', check[:status], body
    end
  end

  test 'rejects contradictory error or transaction content even with a company name' do
    ['<error>Private error</error>', '<transaction><transaction_id>Private ID</transaction_id></transaction>',
     '<response_code>300</response_code>', '<response_text>Denied</response_text>'].each do |content|
      stub_check(body: "<nm_response><merchant><company>Private merchant</company></merchant>#{content}</nm_response>")
      assert_equal 'failed', check[:status]
    end
  end

  test 'malformed XML HTML and invalid UTF8 are sanitized' do
    ['<nm_response><merchant><company>Private unclosed', '<html>Private login</html>',
     'not XML', "\xFF".b + profile_xml.b].each do |body|
      stub_check(body: body)
      result = check
      assert_equal 'failed', result[:status]
      refute_includes result.to_json, 'Private'
    end
  end

  test 'rejects DTD internal entities and external entity resolution before parsing' do
    [
      '<!DOCTYPE nm_response><nm_response><merchant><company>Private merchant</company></merchant></nm_response>',
      '<!DOCTYPE nm_response [<!ENTITY secret "Private entity">]><nm_response><merchant><company>&secret;</company></merchant></nm_response>',
      '<!DOCTYPE nm_response SYSTEM "https://evil.example/private.dtd"><nm_response><merchant><company>Private merchant</company></merchant></nm_response>',
      '<!DOCTYPE nm_response [<!ENTITY secret SYSTEM "file:///etc/passwd">]><nm_response><merchant><company>&secret;</company></merchant></nm_response>',
      '<?xml version="1.0" encoding="UTF-16"?>'.encode('UTF-16LE').b + profile_xml.encode('UTF-16LE').b
    ].each do |body|
      stub_check(body: body)
      assert_equal 'failed', check[:status]
    end
    assert_not_requested(:any, 'https://evil.example/private.dtd')
  end

  test 'HTTP credential failures return fixed messages without raw response data' do
    [401, 403].each do |status|
      stub_check(status: status, body: 'private merchant details')
      result = check
      assert_equal 'failed', result[:status]
      assert_includes result[:message], 'did not verify the API credentials'
      refute_includes result.to_json, 'private merchant'
    end
  end

  test 'redirects do not forward merchant security keys' do
    request = stub_check(status: 302, body: '', headers: { 'Location' => 'https://evil.example/collect' })

    assert_equal 'failed', check[:status]
    assert_requested request, times: 1
    assert_not_requested(:any, 'https://evil.example/collect')
  end

  test 'bounds declared and streamed merchant profile response sizes' do
    oversized = 'x' * (PaymentProviders::NmiCheck::MAX_RESPONSE_BYTES + 1)
    stub_check(body: oversized)
    assert_equal 'failed', check[:status]
    stub_check(headers: { 'Content-Length' => oversized.bytesize.to_s })
    assert_equal 'failed', check[:status]
  end

  test 'timeouts do not retry and TLS exceptions never expose credentials' do
    request = stub_request(:post, @sandbox_url).to_timeout
    result = check
    assert_equal 'failed', result[:status]
    assert_includes result[:message], 'could not be reached securely'
    assert_requested request, times: 1

    stub_request(:post, @sandbox_url).to_raise(OpenSSL::SSL::SSLError.new('dedicated-private-merchant-api-key certificate'))
    result = check
    assert_equal 'failed', result[:status]
    refute_includes result.to_json, @credentials['security_key']
  end

  test 'undocumented success and server statuses do not verify merchant access' do
    [204, 202, 500].each do |status|
      stub_check(status: status, body: 'Private diagnostics')
      result = check
      assert_equal 'failed', result[:status]
      refute_includes result.to_json, 'Private diagnostics'
    end
  end

  private

  def check(credentials: @credentials, environment: 'sandbox')
    PaymentProviders::NmiCheck.call(credentials: credentials, environment: environment)
  end

  def profile_xml
    '<nm_response><merchant><company>Private merchant &amp; Co</company><email>private@example.invalid</email></merchant><account_details><account_status>active</account_status></account_details></nm_response>'
  end

  def stub_check(environment: 'sandbox', status: 200, body: profile_xml, headers: {})
    endpoint = environment == 'production' ? @production_url : @sandbox_url
    stub_request(:post, endpoint)
      .with(body: { 'security_key' => @credentials['security_key'], 'report_type' => 'profile' },
        headers: { 'Content-Type' => 'application/x-www-form-urlencoded', 'Accept-Encoding' => 'identity' })
      .to_return(status: status, body: body, headers: headers)
  end
end
