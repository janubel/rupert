# frozen_string_literal: true

require 'test_helper'

class AuthorizeNetReportingIntegrationTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = tenants(:default_tenant)
    @owner = users(:regular_user)
    Current.tenant = @tenant
    post login_path, params: { email: @owner.email, password: 'password' }
    @path = pos_connection_path('authorize_net_reporting')
  end
  teardown { Current.reset }

  test 'encrypted reporting setup has blank secrets and no implicit network or jobs' do
    assert_no_enqueued_jobs do
      patch @path, params: { pos_connection: { account_reference: '12345', environment: 'sandbox', vendor_approved: true,
        credential_secret: { api_login_id: 'synthetic-login', transaction_key: 'synthetic-key' } } }
    end
    assert_response :redirect
    get @path
    assert_response :success
    assert_equal 'no-store', response.headers['Cache-Control']
    assert_select 'input[type="password"][value]', count: 0
    assert_select 'input[name="pos_connection[reporting_enabled]"]'
    assert_select 'input[type="submit"][value="Import reporting data"]'
    refute_includes response.body, 'synthetic-key'
    assert_enqueued_with(job: AuthorizeNetReportingJob) do
      post import_reporting_pos_connection_path('authorize_net_reporting')
    end
    assert_response :redirect
    get @path
    assert_includes response.body, 'Processing fees are unavailable'
    post disconnect_pos_connection_path('authorize_net_reporting')
    assert_response :redirect
    connection = PosConnection.find_by!(provider: 'authorize_net_reporting')
    assert_empty connection.credential_values
    refute connection.reporting_enabled
  end

  test 'method changes clear old secrets and expose only chosen fields' do
    patch @path, params: { pos_connection: { reporting_auth_mode: 'oauth' } }
    assert_response :redirect
    get @path
    assert_select 'input[name="pos_connection[credential_secret][refresh_token]"]'
    assert_select 'input[name="pos_connection[credential_secret][transaction_key]"]', count: 0
  end

  test 'invalid configuration and unapproved imports fail locally' do
    patch @path, params: { pos_connection: { reporting_enabled: true } }
    assert_response :unprocessable_entity
    post import_reporting_pos_connection_path('authorize_net_reporting')
    assert_response :redirect
    assert_equal 0, AuthorizeNetTransaction.count
    post import_reporting_pos_connection_path('authorize_net_reporting'), params: { from: 'bogus' }
    assert_response :redirect
  end

  test 'daily totals cover all rows and exclude unknown currency amounts' do
    Current.tenant = @tenant
    PosConnection.create!(provider: 'authorize_net_reporting', account_reference: '12345')
    rows = 101.times.map do |i|
      { tenant_id: @tenant.id, environment: 'sandbox', gateway_id: '12345', source_transaction_id: (i + 1).to_s,
        transaction_type: 'authCaptureTransaction', payment_status: 'settledSuccessfully',
        submitted_at: Time.utc(2026, 10, 15, 12), settled_at: Time.utc(2026, 10, 15, 18),
        currency: 'USD', authorized_amount: '1.25', settled_amount: '1.25', observed_at: Time.current }
    end
    AuthorizeNetTransaction.insert_all!(rows)
    AuthorizeNetTransaction.create!(rows.first.merge(source_transaction_id: '9999', currency: nil, settled_amount: '999.00'))
    get @path, params: { report_date: '2026-10-15' }
    assert_response :success
    assert_includes response.body, '126.25'
    assert_includes response.body, '100 of 102'
    assert_select 'tbody tr', count: 100
    assert_not_includes response.body, '999.00'
    get @path, params: { report_date: 'invalid' }
    assert_response :redirect
  end

  test 'read-only settings permission cannot import reports or change credentials' do
    @owner.update_permission_overrides!(['settings.read'])
    get @path
    assert_response :success
    assert_no_enqueued_jobs { post import_reporting_pos_connection_path('authorize_net_reporting') }
    assert_response :redirect
    patch @path, params: { pos_connection: { reporting_enabled: true } }
    assert_response :redirect
  end

  test 'reporting action is restricted to its own provider' do
    post import_reporting_pos_connection_path('valmar')
    assert_response :not_found
  end
end
