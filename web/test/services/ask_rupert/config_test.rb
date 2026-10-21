# frozen_string_literal: true

require 'test_helper'

class AskRupertConfigTest < ActiveSupport::TestCase
  setup { Current.tenant = tenants(:default_tenant) }
  teardown { Current.reset }

  test 'defaults are light and on' do
    config = AskRupert::Config.current
    assert config.enabled?
    assert_equal 20, config['rate_limit_count']
    assert_equal 10, config['rate_limit_window_minutes']
    assert_equal 'cloud', config.mode
  end

  test 'saved values are clamped, typed and limited to the editable keys' do
    AskRupert::Config.update!('rate_limit_count' => '5000', 'daily_cap' => '0', 'provider_mode' => 'local_only', 'enabled' => '0',
      'retention_days' => 'abc', 'local_url' => 'http://evil.example', 'unknown' => 'x')
    config = AskRupert::Config.current
    assert_equal 200, config['rate_limit_count']
    assert_equal 1, config['daily_cap']
    assert config.local_only?
    assert_not config.enabled?
    assert_equal 30, config['retention_days']
    assert_nil config.local_url, 'the local model address is instance configuration, not a setting'
  end

  test 'settings are per workspace' do
    AskRupert::Config.update!('daily_cap' => '7')
    Current.tenant = Tenant.create!(name: 'Elsewhere', subdomain: 'elsewhere-ask')
    assert_equal 200, AskRupert::Config.current['daily_cap']
  end
end
