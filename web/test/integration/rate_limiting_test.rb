# frozen_string_literal: true

require 'test_helper'

class RateLimitingTest < ActionDispatch::IntegrationTest
  setup do
    # Rack::Attack counts per fixed time window; a run that crossed a window
    # boundary reset the counter and the expected 429 never came. Freeze time.
    freeze_time
    Rack::Attack.enabled = true
    Rack::Attack.cache.store.clear
    @tenant = tenants(:default_tenant)
    @admin = User.create!(email: 'limits@example.com', password: 'password123', role: 'super_admin', tenant_id: @tenant.id, name: 'Limits')
  end

  teardown do
    Rack::Attack.cache.store.clear
    Rack::Attack.enabled = false
    unfreeze_time
  end

  test 'secret-bearing settings endpoints are throttled per IP with a Retry-After header' do
    post login_path, params: { email: 'limits@example.com', password: 'password123' }
    limit = Rack::Attack.throttles['settings-secrets/ip'].limit
    limit.times do
      get '/settings/env.json'
      assert_response :success
    end
    get '/settings/env.json'
    assert_response :too_many_requests
    assert_match(/\A\d+\z/, response.headers['Retry-After'])
    assert_equal 'rate_limited', response.parsed_body.dig('error', 'code')
  end

  test 'password login is throttled per email before the database lockout counts failures' do
    limit = Rack::Attack.throttles['login/email'].limit
    limit.times do
      post login_path, params: { email: 'limits@example.com', password: 'wrong' }
      assert_response :unprocessable_entity
    end
    post login_path, params: { email: 'limits@example.com', password: 'wrong' }
    assert_response :too_many_requests
  end

  test 'health checks are never throttled' do
    (Rack::Attack.throttles['all/ip'].limit + 5).times { get '/up' }
    assert_response :success
  end

  test 'the bearer API is throttled per token, not per IP, when a token is presented' do
    limit = Rack::Attack.throttles['api/ip'].limit
    limit.times { get '/api/v1/catalog' }
    get '/api/v1/catalog'
    assert_response :too_many_requests, 'unauthenticated calls share the per-IP bucket'

    get '/api/v1/catalog', headers: { 'Authorization' => 'Bearer rupert_not-a-real-token-but-shaped-like-one-000000000' }
    assert_response :unauthorized, 'a presented token uses its own bucket and reaches authentication'
  end

  test 'the MCP endpoint has its own per-token bucket' do
    headers = { 'Authorization' => 'Bearer rupert_not-a-real-token-but-shaped-like-one-000000000', 'Content-Type' => 'application/json' }
    body = { jsonrpc: '2.0', id: 1, method: 'ping' }.to_json
    Rack::Attack.throttles['mcp/token'].limit.times do
      post '/mcp', params: body, headers: headers
      assert_response :unauthorized
    end
    post '/mcp', params: body, headers: headers
    assert_response :too_many_requests
    get '/api/v1/catalog', headers: headers
    assert_response :unauthorized, 'the REST API bucket is separate'
  end
end
