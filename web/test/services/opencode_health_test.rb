# frozen_string_literal: true

require 'test_helper'
require 'tempfile'

class OpencodeHealthTest < ActiveSupport::TestCase
  ZEN = 'https://opencode.ai/zen/v1/models'
  GO = 'https://opencode.ai/zen/go/v1/models'
  SECRET = 'sk-test-secret-key-do-not-leak'

  setup do
    AiHealthCheck.delete_all
    @env = ENV.to_h.slice('OPENCODE_API_KEY', 'OPENCODE_AUTH_FILE', 'OPENCODE_PROVIDER', 'OPENCODE_MODEL', 'OPENCODE_HEALTH_PROBE')
    %w[OPENCODE_API_KEY OPENCODE_AUTH_FILE OPENCODE_PROVIDER OPENCODE_MODEL OPENCODE_HEALTH_PROBE].each { |k| ENV.delete(k) }
    ENV['OPENCODE_API_KEY'] = SECRET
  end

  teardown do
    %w[OPENCODE_API_KEY OPENCODE_AUTH_FILE OPENCODE_PROVIDER OPENCODE_MODEL OPENCODE_HEALTH_PROBE].each { |k| ENV.delete(k) }
    @env.each { |k, v| ENV[k] = v }
  end

  def catalog(*ids) = { data: ids.map { |id| { id: id, object: 'model' } } }.to_json

  def stub_catalogs(zen: %w[big-pickle beam-free deepseek-v4.1-flash-free deepseek-v4-flash], go: %w[deepseek-v4-flash deepseek-v4-pro])
    stub_request(:get, ZEN).to_return(status: 200, body: catalog(*zen))
    stub_request(:get, GO).with(headers: { 'Authorization' => "Bearer #{SECRET}" }).to_return(status: 200, body: catalog(*go))
  end

  test 'healthy: valid key, live free models, configured model offered' do
    stub_catalogs
    check = OpencodeHealth.check!
    assert_equal 'ok', check.status
    assert_equal 'valid', check.key_state
    assert_equal 'available', check.model_state
    assert_equal 'deepseek-v4-flash', check.configured_model
    assert_equal %w[beam-free deepseek-v4.1-flash-free], check.free_models
    assert_equal 2, check.free_model_count
    assert_equal 2, check.catalog_size
    assert_not check.rate_limited
    assert_not_nil check.latency_ms
  end

  test 'the free list is read live, never hard-coded' do
    stub_catalogs(zen: %w[brand-new-free other])
    assert_equal %w[brand-new-free], OpencodeHealth.check!.free_models
  end

  test 'an expired key is an error carrying the vendor code but no message text' do
    stub_request(:get, ZEN).to_return(status: 200, body: catalog('beam-free'))
    stub_request(:get, GO).to_return(status: 401, body: { error: { type: 'authentication_error', code: 'api_key_expired', message: "This API key #{SECRET} has expired" } }.to_json)
    check = OpencodeHealth.check!
    assert_equal 'error', check.status
    assert_equal 'expired', check.key_state
    assert_equal 'auth', check.error_type
    assert_equal 'api_key_expired', check.error_code
    assert_equal 401, check.http_status
    assert_equal 1, check.free_model_count
    assert_not_includes check.attributes.values.join(' '), SECRET
  end

  test 'a rejected key without a vendor code is invalid' do
    stub_request(:get, ZEN).to_return(status: 200, body: catalog('beam-free'))
    stub_request(:get, GO).to_return(status: 401, body: '{"error":{"type":"server_error","message":"Upstream request failed: Invalid credential"}}')
    check = OpencodeHealth.check!
    assert_equal 'invalid', check.key_state
    assert_nil check.error_code
  end

  test 'a model the provider no longer offers is flagged' do
    stub_catalogs(go: %w[deepseek-v4-pro])
    check = OpencodeHealth.check!
    assert_equal 'missing', check.model_state
    assert_equal 'warning', check.status
  end

  test 'the model and provider are configurable' do
    ENV['OPENCODE_MODEL'] = 'opencode-go/deepseek-v4-pro'
    stub_catalogs
    assert_equal 'available', OpencodeHealth.check!.model_state
  end

  test 'a 429 is reported as a rate limit with its retry-after' do
    stub_request(:get, ZEN).to_return(status: 429, headers: { 'Retry-After' => '30' }, body: '{"error":{"code":"rate_limit_exceeded"}}')
    stub_request(:get, GO).to_return(status: 200, body: catalog('deepseek-v4-flash'))
    check = OpencodeHealth.check!
    assert check.rate_limited
    assert_equal 30, check.retry_after_seconds
    assert_equal 'rate_limited', check.error_type
    assert_equal 'rate_limit_exceeded', check.error_code
    assert_equal 'warning', check.status
  end

  test 'a provider timeout is recorded as such and is an error' do
    stub_request(:get, ZEN).to_return(status: 200, body: catalog('beam-free'))
    stub_request(:get, GO).to_timeout
    check = OpencodeHealth.check!
    assert_equal 'timeout', check.error_type
    assert_equal 'unchecked', check.key_state
    assert_equal 'error', check.status
  end

  test 'a network failure reaching opencode is an error' do
    stub_request(:get, ZEN).to_raise(SocketError)
    stub_request(:get, GO).to_raise(Errno::ECONNREFUSED)
    check = OpencodeHealth.check!
    assert_equal 'network', check.error_type
    assert_equal 'error', check.status
    assert_equal 0, check.free_model_count
  end

  test 'a missing key still reports the free models and is not an error' do
    ENV.delete('OPENCODE_API_KEY')
    ENV['OPENCODE_AUTH_FILE'] = '/nonexistent/auth.json'
    stub_request(:get, ZEN).to_return(status: 200, body: catalog('beam-free'))
    check = OpencodeHealth.check!
    assert_equal 'not_configured', check.status
    assert_equal 'missing', check.key_state
    assert_equal %w[beam-free], check.free_models
    assert_not_requested :get, GO
  end

  test 'the key can come from the opencode auth file' do
    ENV.delete('OPENCODE_API_KEY')
    Tempfile.create('auth.json') do |file|
      file.write({ 'opencode-go' => { 'type' => 'api', 'key' => SECRET } }.to_json)
      file.flush
      ENV['OPENCODE_AUTH_FILE'] = file.path
      stub_catalogs
      assert_equal 'valid', OpencodeHealth.check!.key_state
    end
  end

  test 'the optional probe sends one token to the first free model and sees its rate limit' do
    ENV['OPENCODE_HEALTH_PROBE'] = '1'
    stub_catalogs
    chat = stub_request(:post, 'https://opencode.ai/zen/v1/chat/completions')
      .with { |req| JSON.parse(req.body).values_at('model', 'max_tokens') == ['beam-free', 1] }
      .to_return(status: 429, body: '{}')
    check = OpencodeHealth.check!
    assert_requested chat
    assert check.rate_limited
    assert_equal 'warning', check.status
  end

  test 'the probe is off by default' do
    stub_catalogs
    OpencodeHealth.check!
    assert_not_requested :post, 'https://opencode.ai/zen/v1/chat/completions'
  end

  test 'the key is sent only to opencode and never stored' do
    stub_catalogs
    OpencodeHealth.check!
    assert_requested(:get, GO) { |req| req.headers['Authorization'] == "Bearer #{SECRET}" }
    assert_not_requested(:get, ZEN) { |req| req.headers['Authorization'].present? }
    assert_empty AiHealthCheck.all.select { |c| c.attributes.values.join.include?(SECRET) }
  end

  test 'old checks are pruned' do
    AiHealthCheck.create!(status: 'ok', checked_at: 100.days.ago)
    stub_catalogs
    OpencodeHealth.check!
    assert_equal 1, AiHealthCheck.count
  end
end
