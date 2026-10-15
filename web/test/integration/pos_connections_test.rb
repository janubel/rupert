# frozen_string_literal: true

require 'test_helper'

class PosConnectionsTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = tenants(:default_tenant)
    @owner = users(:regular_user)
    Current.tenant = @tenant
    login
    @credentials = { api_url: 'https://167.koronacloud.com/web/api/v3',
      account_id: '11111111-2222-3333-4444-555555555555', api_username: 'dedicated-read-user', api_password: 'private-api-password' }
  end

  teardown { Current.reset }

  test 'hub distinguishes current providers and evaluation paths' do
    get pos_connections_path
    assert_response :success
    %w[Valmar PAX C-Trax SwipeSimple KORONA Cova Shopify Square].each { |name| assert_includes response.body, name }
    assert_select 'a[href=?]', pos_connection_path('cova')
    assert_equal 'no-store', response.headers['Cache-Control']
    assert_select 'meta[name="turbo-cache-control"][content="no-cache"]'
    get pos_connection_path('swipesimple')
    assert_select 'a[href=?]', syncs_path(anchor: 'swipesimple')
    assert_includes response.body, 'does not publish a payments integration API'
    get pos_connection_path('valmar')
    assert_select 'select[name="pos_connection[gateway]"]'
    assert_select 'input[name*="credential_secret"]', count: 0
    assert_select 'button', text: 'Check read access', count: 0
  end

  test 'saving is local and credentials stay encrypted and never redisplay' do
    PaymentProviders::KoronaCheck.expects(:call).never
    assert_no_enqueued_jobs do
      save_korona
    end
    assert_redirected_to pos_connection_path('korona')
    connection = current_connection
    assert connection.credentials_saved?
    assert_nil connection.last_checked_at
    assert_equal 'Credentials saved · not checked', connection.status_label
    raw = PosConnection.connection.select_value("SELECT credentials_json FROM pos_connections WHERE id = #{connection.id}")
    assert_not_includes raw, 'private-api-password'
    assert_not_includes raw, 'dedicated-read-user'
    assert_equal 'private-api-password', connection.credential_values['api_password']
    follow_redirect!
    assert_select 'input[type="password"]', count: 4
    assert_select 'input[type="password"][value]', count: 0
    assert_not_includes response.body, 'private-api-password'
    assert_not_includes response.body, 'dedicated-read-user'
    assert_select 'button', text: 'Check read access'
  end

  test 'provider credentials are filtered before request instrumentation' do
    captured = []
    subscriber = ActiveSupport::Notifications.subscribe('start_processing.action_controller') do |_name, _start, _finish, _id, payload|
      captured << payload[:params] if payload[:controller] == 'PosConnectionsController'
    end
    save_korona
    serialized = captured.to_json
    assert_includes serialized, '[FILTERED]'
    assert_not_includes serialized, 'private-api-password'
    assert_not_includes serialized, 'dedicated-read-user'
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  test 'invalid vendor endpoints and missing approval cannot be stored or contacted' do
    PaymentProviders::KoronaCheck.expects(:call).never
    ['http://167.koronacloud.com/web/api/v3', 'https://127.0.0.1/web/api/v3',
      'https://167.koronacloud.com.evil.invalid/web/api/v3', 'https://167.koronacloud.com/web/api/v3?token=secret'].each do |url|
      assert_no_difference -> { PosConnection.unscoped.count } do
        save_korona(credentials: @credentials.merge(api_url: url))
        assert_response :unprocessable_entity
      end
    end
    save_korona(approved: false)
    assert_response :unprocessable_entity
    assert_not_includes response.body, 'private-api-password'
    assert_nil PosConnection.unscoped.find_by(tenant_id: @tenant.id, provider: 'korona')
  end

  test 'approved Cova credentials need full onboarding package and bounded company ID' do
    credentials = { company_id: '42', client_id: 'api-client', client_secret: 'cova-private-secret',
      api_username: 'cova-user', api_password: 'cova-password' }
    patch pos_connection_path('cova'), params: { pos_connection: { vendor_approved: true,
      credential_secret: credentials.except(:client_secret) } }
    assert_response :unprocessable_entity
    patch pos_connection_path('cova'), params: { pos_connection: { vendor_approved: true,
      credential_secret: credentials.merge(company_id: '9999999999') } }
    assert_response :unprocessable_entity
    patch pos_connection_path('cova'), params: { pos_connection: { vendor_approved: true, credential_secret: credentials } }
    assert_response :redirect
    assert_equal 'api-client', current_connection('cova').credential_values['client_id']
    get pos_connection_path('cova')
    assert_not_includes response.body, 'cova-private-secret'
    assert_not_includes response.body, 'cova-password'
    assert_select 'input[type="password"]', count: 5
  end

  test 'read-only settings permission cannot save check or remove credentials' do
    save_korona
    @owner.update_permission_overrides!(['settings.read'])
    get pos_connection_path('korona')
    assert_response :success
    assert_select 'input[type="password"]', count: 0
    assert_select 'button', text: 'Check read access', count: 0
    PaymentProviders::KoronaCheck.expects(:call).never
    version = current_connection.lock_version
    patch pos_connection_path('korona'), params: { pos_connection: { account_reference: 'denied' } }
    assert_response :redirect
    post check_access_pos_connection_path('korona')
    assert_response :redirect
    post disconnect_pos_connection_path('korona')
    assert_response :redirect
    assert_equal version, current_connection.lock_version
    assert current_connection.credentials_saved?
  end

  test 'tenant setup and provider tampering cannot read or mutate another tenant' do
    other = Tenant.create!(name: 'Other provider store', subdomain: 'other-providers')
    connection = PosConnection.unscoped.create!(tenant: other, provider: 'korona', account_reference: 'OTHER-PRIVATE-STORE',
      vendor_approved: true, credentials_json: @credentials.to_json)
    get pos_connection_path('korona')
    assert_response :success
    assert_not_includes response.body, 'OTHER-PRIVATE-STORE'
    patch pos_connection_path('korona'), params: { pos_connection: { tenant_id: other.id, provider: 'cova',
      account_reference: 'OWN-STORE' } }
    assert_response :redirect
    assert_equal 'OTHER-PRIVATE-STORE', connection.reload.account_reference
    assert_equal @tenant.id, current_connection.tenant_id
    assert_equal 'korona', current_connection.provider
    post disconnect_pos_connection_path('korona')
    assert_response :redirect
    assert_nil connection.reload.last_checked_at
    assert connection.credentials_saved?
    get pos_connection_path('unknown-provider')
    assert_response :not_found
  end

  test 'explicit check stores sanitized verification and rotation clears it' do
    save_korona
    PaymentProviders::KoronaCheck.expects(:call).with(credentials: @credentials.stringify_keys)
      .returns(status: 'verified', message: 'KORONA organizational-unit read access verified. Payments and terminals are not enabled.')
    post check_access_pos_connection_path('korona')
    assert_response :redirect
    connection = current_connection
    assert_equal 'verified', connection.last_check_status
    assert connection.last_checked_at
    assert_equal 'Read access checked', connection.status_label
    patch pos_connection_path('korona'), params: { pos_connection: { lock_version: connection.lock_version,
      credential_secret: { api_password: 'replacement-api-password' } } }
    assert_response :redirect
    assert_nil connection.reload.last_check_status
    assert_nil connection.last_checked_at
    assert_equal 'replacement-api-password', connection.credential_values['api_password']
  end

  test 'concurrent setup change cannot receive a stale successful check' do
    save_korona
    stub_request(:get, /koronacloud\.com/).to_return do
      current_connection.update!(account_reference: 'Changed during check')
      { status: 200, body: { currentPage: 1, results: [], resultsOfPage: 0, resultsTotal: 0 }.to_json }
    end
    post check_access_pos_connection_path('korona')
    assert_response :redirect
    assert_match(/changed during/, flash[:alert])
    assert_nil current_connection.last_check_status
  end

  test 'removing credentials during a check cannot restore verification' do
    save_korona
    stub_request(:get, /koronacloud\.com/).to_return do
      current_connection.update!(credentials_json: '{}')
      { status: 200, body: { currentPage: 1, results: [], resultsOfPage: 0, resultsTotal: 0 }.to_json }
    end
    post check_access_pos_connection_path('korona')
    assert_response :redirect
    assert_match(/changed during/, flash[:alert])
    assert_empty current_connection.credential_values
    assert_nil current_connection.last_check_status
  end

  test 'stale form cannot overwrite a newer account setup' do
    save_korona
    original_version = current_connection.lock_version
    patch pos_connection_path('korona'), params: { pos_connection: { lock_version: original_version, account_reference: 'First save' } }
    assert_response :redirect
    patch pos_connection_path('korona'), params: { pos_connection: { lock_version: original_version, account_reference: 'Stale save' } }
    assert_response :redirect
    assert_match(/another session/, flash[:alert])
    assert_equal 'First save', current_connection.account_reference
  end

  test 'environment switch and disconnect remove local secrets and verification' do
    save_korona
    patch pos_connection_path('korona'), params: { pos_connection: { environment: 'production' } }
    assert_response :redirect
    assert_empty current_connection.credential_values
    assert_nil current_connection.last_check_status
    save_korona
    post disconnect_pos_connection_path('korona')
    assert_response :redirect
    assert_empty current_connection.credential_values
    get pos_connection_path('korona')
    assert_select 'button', text: 'Check read access', count: 0
  end

  test 'unsupported providers cannot run speculative checks and inactive tenants cannot save' do
    PaymentProviders::KoronaCheck.expects(:call).never
    post check_access_pos_connection_path('valmar')
    assert_response :redirect
    assert_match(/approved API credentials/, flash[:alert])
    @tenant.update!(status: 'suspended')
    patch pos_connection_path('korona'), params: { pos_connection: { account_reference: 'Denied' } }
    assert_response :forbidden
    assert_nil PosConnection.unscoped.find_by(tenant_id: @tenant.id)
  end

  private

  def login
    post login_path, params: { email: @owner.email, password: 'password' }
    assert_response :redirect
  end

  def current_connection(provider = 'korona')
    PosConnection.unscoped.find_by!(tenant_id: @tenant.id, provider: provider)
  end

  def save_korona(credentials: @credentials, approved: true)
    patch pos_connection_path('korona'), params: { pos_connection: { environment: 'sandbox', vendor_approved: approved,
      credential_secret: credentials } }
  end
end
