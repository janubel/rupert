# frozen_string_literal: true

require 'test_helper'

class ConnectionCredentialsTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @actor = users(:regular_user)
    @tenant = tenants(:default_tenant)
    post login_path, params: { email: @actor.email, password: 'password' }
    Current.user = @actor
    EnvStore.set('SQUARE_ACCESS_TOKEN', 'test-only-private-token')
  end

  teardown { Current.reset }

  def edit_token(service = 'square')
    get edit_connection_path(service)
    assert_response :success
    css_select('input[name="connection_credentials[edit_token]"]').first['value']
  end

  def submit(values, token: edit_token, clear: [], service: 'square')
    patch connection_path(service), params: { connection_credentials: { values: values, clear_keys: clear, edit_token: token } }
  end

  test 'named form hides saved secrets and opening the hub or form starts no job' do
    assert_no_enqueued_jobs { edit_token }
    assert_select 'input[name="connection_credentials[values][SQUARE_ACCESS_TOKEN]"][type=password][value=""]'
    refute_includes response.body, 'test-only-private-token'
    assert_equal 'no-store', response.headers['Cache-Control']
    assert_equal 'no-referrer', response.headers['Referrer-Policy']
    assert_no_enqueued_jobs { get connections_path }
    assert_response :success
    refute_includes response.body, 'test-only-private-token'
    assert_select '#improvements'
    assert_select '[data-credential-service=ctrax]'
    assert_select '[data-credential-service=authorize_net_reporting]'
  end

  test 'saving uses existing encrypted tenant settings and blank secrets are preserved' do
    token = edit_token
    assert_no_enqueued_jobs { submit({ SQUARE_ACCESS_TOKEN: '', SQUARE_ENVIRONMENT: 'sandbox' }, token: token) }
    assert_redirected_to edit_connection_path('square')
    assert_equal 'test-only-private-token', EnvStore.fetch('SQUARE_ACCESS_TOKEN')
    assert_equal 'sandbox', EnvStore.fetch('SQUARE_ENVIRONMENT')
    token = edit_token
    submit({ SQUARE_ACCESS_TOKEN: 'test-only-replacement' }, token: token)
    assert_equal 'test-only-replacement', Setting.find_by!(key: 'SQUARE_ACCESS_TOKEN', tenant_id: @tenant.id).value
    refute_includes Setting.find_by!(key: 'SQUARE_ACCESS_TOKEN', tenant_id: @tenant.id).value_before_type_cast, 'test-only-replacement'
    follow_redirect!
    refute_includes response.body, 'test-only-replacement'
  end

  test 'an explicit removal affects only the selected setting' do
    EnvStore.set('SQUARE_ENVIRONMENT', 'production')
    submit({}, clear: ['SQUARE_ACCESS_TOKEN'])
    assert_redirected_to edit_connection_path('square')
    assert_nil Setting.find_by(key: 'SQUARE_ACCESS_TOKEN', tenant_id: @tenant.id)
    assert_equal 'production', EnvStore.fetch('SQUARE_ENVIRONMENT')
  end

  test 'stale and expired forms cannot replace credentials' do
    token = edit_token
    EnvStore.set('SQUARE_ACCESS_TOKEN', 'newer-test-only-token')
    submit({ SQUARE_ACCESS_TOKEN: 'old-form-token' }, token: token)
    assert_match(/setup changed/, flash[:alert])
    assert_equal 'newer-test-only-token', EnvStore.fetch('SQUARE_ACCESS_TOKEN')
    token = edit_token
    travel 16.minutes do
      submit({ SQUARE_ACCESS_TOKEN: 'expired-form-token' }, token: token)
      assert_match(/expired/, flash[:alert])
      assert_equal 'newer-test-only-token', EnvStore.fetch('SQUARE_ACCESS_TOKEN')
    end
  end

  test 'tokens are bound to the actor and service' do
    token = edit_token
    other = User.create!(email: 'other-credentials@example.invalid', password: 'test-password', role: 'admin', tenant: @tenant)
    delete logout_path
    post login_path, params: { email: other.email, password: 'test-password' }
    submit({ SQUARE_ACCESS_TOKEN: 'foreign-actor-token' }, token: token)
    assert_match(/setup changed/, flash[:alert])
    assert_equal 'test-only-private-token', EnvStore.fetch('SQUARE_ACCESS_TOKEN')
    token = edit_token
    submit({ SHOPIFY_CLIENT_SECRET: 'wrong-service-secret' }, token: token, service: 'shopify')
    assert_match(/setup changed/, flash[:alert])
    assert_nil Setting.find_by(key: 'SHOPIFY_CLIENT_SECRET', tenant_id: @tenant.id)
  end

  test 'foreign workspace tokens and provider metadata cannot cross tenant boundaries' do
    token = edit_token
    other_tenant = Tenant.create!(name: 'Other test workspace', subdomain: 'credential-other')
    other = User.create!(email: 'other-workspace@example.invalid', password: 'test-password', role: 'admin', tenant: other_tenant)
    delete logout_path
    post login_path, params: { email: other.email, password: 'test-password' }
    submit({ SQUARE_ACCESS_TOKEN: 'foreign-workspace-token' }, token: token)
    assert_match(/setup changed/, flash[:alert])
    assert_nil Setting.find_by(key: 'SQUARE_ACCESS_TOKEN', tenant_id: other_tenant.id)
    get connections_path
    assert_select '[data-credential-service=square]', text: /Not configured/
  end

  test 'invalid fields fail atomically without echoing input or changing another service' do
    token = edit_token
    submit({ SQUARE_ACCESS_TOKEN: 'do-not-save', GOOGLE_DRIVE_CLIENT_SECRET: 'do-not-echo' }, token: token)
    assert_match(/Unsupported/, flash[:alert])
    refute_includes flash[:alert], 'do-not-echo'
    assert_equal 'test-only-private-token', EnvStore.fetch('SQUARE_ACCESS_TOKEN')
    assert_nil Setting.find_by(key: 'GOOGLE_DRIVE_CLIENT_SECRET')
    submit({ SQUARE_ACCESS_TOKEN: 'do-not-save', SQUARE_ENVIRONMENT: 'bad-environment' })
    assert_match(/supported environment/, flash[:alert])
    assert_equal 'test-only-private-token', EnvStore.fetch('SQUARE_ACCESS_TOKEN')
    submit({ SQUARE_ACCESS_TOKEN: 'do-not-save' }, clear: ['SQUARE_ACCESS_TOKEN'])
    assert_match(/replacement or removal/, flash[:alert])
    assert_equal 'test-only-private-token', EnvStore.fetch('SQUARE_ACCESS_TOKEN')
  end

  test 'read-only settings access has no forms or mutation permission' do
    reader = User.create!(email: 'setup-reviewer@example.invalid', password: 'test-password', role: 'reader', tenant: @tenant)
    reader.update_permission_overrides!(['settings.read'])
    delete logout_path
    post login_path, params: { email: reader.email, password: 'test-password' }
    get edit_connection_path('square')
    assert_response :success
    assert_select 'form[action=?]', connection_path('square'), count: 0
    refute_includes response.body, 'test-only-private-token'
    patch connection_path('square'), params: { connection_credentials: { values: { SQUARE_ACCESS_TOKEN: 'forbidden' } } }
    assert_response :redirect
    assert_equal 'test-only-private-token', EnvStore.fetch('SQUARE_ACCESS_TOKEN')
    get connections_path
    assert_select 'form[action*="check_access"]', count: 0
    assert_select 'form[action*="source_syncs"]', count: 0
    assert_select '[data-credential-service=google_drive]', count: 0
    assert_select '[data-connection-source=google_backup]', count: 0
  end

  test 'platform and arbitrary service paths are not editable through the tenant form' do
    get edit_connection_path('google_drive')
    assert_response :not_found
    get edit_connection_path('not-a-provider')
    assert_response :not_found
  end

  test 'unreadable secrets have a repair message and cannot be overwritten' do
    original = EnvStore.method(:fetch)
    unreadable = lambda do |*args|
      raise ActiveRecord::Encryption::Errors::Decryption, 'test-only-private-error' if args.first == 'SQUARE_ACCESS_TOKEN'

      original.call(*args)
    end
    EnvStore.stub(:fetch, unreadable) do
      get connections_path
      assert_response :success
      assert_select '[data-credential-service=square]', text: /Credentials unreadable/
      refute_includes response.body, 'test-only-private-error'
      token = edit_token
      submit({ SQUARE_ACCESS_TOKEN: 'must-not-overwrite' }, token: token)
      assert_match(/restore the encryption keys/, flash[:alert])
      assert_equal 'test-only-private-token', Setting.find_by!(key: 'SQUARE_ACCESS_TOKEN', tenant_id: @tenant.id).value
    end
  end

  test 'failed storage rolls back earlier field changes and clears cached state' do
    token = edit_token
    original = EnvStore.method(:set)
    replacement = lambda do |key, value|
      original.call(key, value)
      raise ActiveRecord::RecordInvalid.new(Setting.new) if key == 'SQUARE_ACCESS_TOKEN'
    end
    EnvStore.stub(:set, replacement) do
      submit({ SQUARE_ENVIRONMENT: 'sandbox', SQUARE_ACCESS_TOKEN: 'must-roll-back' }, token: token)
    end
    assert_match(/could not be saved safely/, flash[:alert])
    assert_nil Setting.find_by(key: 'SQUARE_ENVIRONMENT', tenant_id: @tenant.id)
    assert_equal 'test-only-private-token', EnvStore.fetch('SQUARE_ACCESS_TOKEN')
  end

  test 'credential form container is filtered from request logging' do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    result = filter.filter('connection_credentials' => { 'values' => { 'BUZZ_CHANNEL' => 'private-input' }, 'edit_token' => 'private-form-token' })
    assert_equal '[FILTERED]', result['connection_credentials']
  end

  test 'provider checks are explicit and the hub hides provider secrets and response messages' do
    connection = PosConnection.create!(provider: 'authorize_net_reporting', environment: 'production',
      account_reference: '4001', vendor_approved: true,
      credentials_json: { api_login_id: 'fixture_login', transaction_key: 'fixture_secret' }.to_json)
    connection.update_columns(last_check_status: 'verified', last_check_message: 'private-provider-response', last_checked_at: Time.current)
    assert_no_enqueued_jobs { get connections_path }
    assert_response :success
    assert_select 'form[action=?]', check_access_pos_connection_path('authorize_net_reporting'), count: 1
    %w[fixture_login fixture_secret private-provider-response].each { |value| refute_includes response.body, value }
  end

  test 'a foreign provider connection never supplies current workspace status or actions' do
    other_tenant = Tenant.create!(name: 'Foreign provider test', subdomain: 'foreign-provider-test')
    Current.tenant = other_tenant
    PosConnection.create!(provider: 'authorize_net_reporting', environment: 'production', account_reference: '4002', vendor_approved: true,
      credentials_json: { api_login_id: 'foreign_login', transaction_key: 'foreign_secret' }.to_json)
    Current.tenant = @tenant
    get connections_path
    assert_select '[data-credential-service=authorize_net_reporting]', text: /Not configured/
    assert_select 'form[action=?]', check_access_pos_connection_path('authorize_net_reporting'), count: 0
    refute_includes response.body, 'foreign_secret'
  end
end
