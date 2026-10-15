# frozen_string_literal: true

require 'test_helper'

class CredentialParameterFilterTest < ActionDispatch::IntegrationTest
  setup do
    Current.tenant = tenants(:default_tenant)
    post login_path, params: { email: 'admin@example.com', password: 'password' }
  end

  teardown { Current.reset }

  test 'connection secrets and raw env text are filtered while nonsecret knobs remain' do
    original = {
      'text' => "SQUARE_ACCESS_TOKEN=raw-env-secret\nSHOPIFY_CLIENT_SECRET=raw-shopify-secret",
      'shopify_client_secret' => 'raw-shopify-secret',
      'shopify_client_id' => 'provider-client-id',
      'square_access_token' => 'raw-square-secret',
      'payment_nonce' => 'raw-payment-nonce',
      'AUTHORIZE_NET_TRANSACTION_KEY' => 'raw-gateway-key',
      'api_login_id' => 'merchant-login',
      'authorization' => 'Bearer raw-bearer-secret',
      'code' => 'raw-oauth-code',
      'provider_credentials' => { 'opaque_value' => 'raw-nested-secret' },
      'provider' => { 'text' => 'raw-nested-env-secret', 'environment' => 'sandbox' },
      'business_name' => 'Visible business name'
    }
    filtered = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters).filter(original)
    %w[text shopify_client_secret shopify_client_id square_access_token payment_nonce AUTHORIZE_NET_TRANSACTION_KEY api_login_id authorization code provider_credentials].each do |key|
      assert_equal '[FILTERED]', filtered[key], "not filtered: #{key}"
    end
    assert_equal '[FILTERED]', filtered.dig('provider', 'text')
    assert_equal 'sandbox', filtered.dig('provider', 'environment')
    assert_equal 'Visible business name', filtered['business_name']
    assert_includes original['text'], 'raw-env-secret'
  end

  test 'settings env preview and import redact text before Rails request instrumentation' do
    captured = []
    listener = lambda do |_name, _started, _finished, _id, payload|
      captured << payload[:params] if payload[:controller] == 'SettingsController'
    end
    secret = 'unique-env-instrumentation-secret'
    ActiveSupport::Notifications.subscribed(listener, 'start_processing.action_controller') do
      post env_preview_settings_path, params: { text: "SQUARE_ACCESS_TOKEN=#{secret}" }
      assert_response :success
      post env_import_settings_path, params: { text: "SQUARE_ACCESS_TOKEN=#{secret}" }
      assert_response :success
    end
    assert_equal 2, captured.length
    captured.each do |params|
      assert_equal '[FILTERED]', params['text']
      refute_includes params.inspect, secret
    end
    assert_equal secret, EnvStore.fetch('SQUARE_ACCESS_TOKEN')
  end
end
