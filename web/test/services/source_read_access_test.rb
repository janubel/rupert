# frozen_string_literal: true

require 'test_helper'

class SourceReadAccessTest < ActiveSupport::TestCase
  setup do
    Current.user = users(:regular_user)
    EnvStore.stubs(:fetch).returns('')
    EnvStore.stubs(:platform_fetch).returns('')
  end
  teardown { Current.reset }

  test 'partial managed setup names only missing required fields without exposing saved values' do
    EnvStore.stubs(:fetch).with('SHOPIFY_CLIENT_ID', '').returns('synthetic-private-client')
    access = SourceReadAccess.for('shopify')
    assert_equal ['Client secret', 'Store domain'], access[:missing_fields]
    refute access[:ready]
    refute_includes access.to_json, 'synthetic-private-client'
    EnvStore.stubs(:fetch).with('SQUARE_ACCESS_TOKEN', '').returns('synthetic-private-token')
    assert SourceReadAccess.for('square')[:ready], 'Optional Square fields must not block reads'
  end

  test 'website and API reporting modes name their own missing credentials' do
    connection = PosConnection.new(provider: 'iris_reporting', reporting_auth_mode: 'web', vendor_approved: true, account_reference: '123456')
    access = SourceReadAccess.for('bank', connection: connection)
    assert_equal ['Website username', 'Website password'], access[:missing_fields]
    connection.reporting_auth_mode = 'api_key'
    assert_equal ['API URL', 'API token'], SourceReadAccess.for('bank', connection: connection)[:missing_fields]
    connection = PosConnection.new(provider: 'authorize_net_reporting', reporting_auth_mode: 'oauth', vendor_approved: true, account_reference: '123456')
    assert_equal ['Client ID', 'Client secret', 'Refresh token'], SourceReadAccess.for('authorize_net', connection: connection)[:missing_fields]
  end

  test 'saved website login without read authorization is not mistaken for rejected credentials' do
    connection = PosConnection.new(provider: 'swipesimple', account_reference: '123456',
      credentials_json: { web_email: 'test@example.invalid', web_password: 'synthetic-private-password' }.to_json)
    before = connection.attributes.deep_dup
    access = SourceReadAccess.for('swipesimple', connection: connection)
    assert_equal 'Read authorization required', access[:state]
    assert_equal ['Read authorization confirmation'], access[:missing_fields]
    refute_includes access.to_json, 'synthetic-private-password'
    refute_includes access.to_json, 'test@example.invalid'
    assert_equal before, connection.attributes
  end

  test 'backup client setup is separate from consent and a folder is created after authorization' do
    access = SourceReadAccess.for('google_backup')
    assert_equal 'Missing access', access[:state]
    assert_equal ['Backup OAuth client ID', 'Backup OAuth client secret'], access[:missing_fields]
    %w[GOOGLE_DRIVE_CLIENT_ID GOOGLE_DRIVE_CLIENT_SECRET].each do |key|
      EnvStore.stubs(:platform_fetch).with(key, '').returns('synthetic-private-value')
    end
    access = SourceReadAccess.for('google_backup')
    assert_equal 'Authorization required', access[:state]
    assert_includes access[:action], 'Backup settings'
    EnvStore.stubs(:platform_fetch).with('GOOGLE_DRIVE_REFRESH_TOKEN', '').returns('synthetic-private-refresh')
    assert SourceReadAccess.for('google_backup')[:ready]
  end
end
