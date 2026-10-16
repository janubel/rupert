# frozen_string_literal: true

require 'test_helper'

class CtraxConnectionsTest < ActionDispatch::IntegrationTest
  setup do
    Current.tenant = tenants(:default_tenant)
    @user = users(:regular_user)
    post login_path, params: { email: @user.email, password: 'password' }
    assert_response :redirect
    @credentials = { api_url: 'https://fixture.api.cannatrax.net', api_username: 'fixture-read-user', api_password: 'private-ctrax-password' }
  end

  teardown { Current.reset }

  test 'C-Trax credentials are encrypted never redisplayed and hourly setting is explicit' do
    save_connection
    assert_response :redirect
    connection = PosConnection.find_by!(provider: 'ctrax')
    assert connection.hourly_sync_enabled
    raw = PosConnection.connection.select_value("SELECT credentials_json FROM pos_connections WHERE id = #{connection.id}")
    assert_not_includes raw, 'private-ctrax-password'
    get pos_connection_path('ctrax')
    assert_response :success
    assert_select 'input[type="password"]', count: 3
    assert_select 'input[type="password"][value]', count: 0
    assert_select 'button', text: 'Sync stock'
    assert_select 'a[href=?]', ctrax_stock_index_path
    assert_not_includes response.body, 'private-ctrax-password'
    post disconnect_pos_connection_path('ctrax')
    assert_response :redirect
    assert_not connection.reload.hourly_sync_enabled
    assert_empty connection.credential_values
  end

  test 'settings-only writer cannot enable or manually start inventory sync' do
    @user.update_permission_overrides!(%w[settings.read settings.write])
    Ctrax::StockSync.expects(:call).never
    save_connection
    assert_response :forbidden
    assert_nil PosConnection.find_by(provider: 'ctrax')
    post sync_stock_pos_connection_path('ctrax')
    assert_response :forbidden
  end

  test 'stock page has no cross-tenant data and respects inventory read permission' do
    other = Tenant.create!(name: 'Private other store', subdomain: 'ctrax-private-other')
    location = Location.unscoped.create!(tenant_id: other.id, source: 'ctrax', externalId: 'other/1',
      name: 'PRIVATE-OTHER-STORE')
    CtraxStockSnapshot.unscoped.create!(tenant_id: other.id, location: location, store_id: '1',
      api_origin: 'https://other.api.cannatrax.net', captured_at: Time.current, records_json: [])
    get ctrax_stock_index_path
    assert_response :success
    assert_not_includes response.body, 'PRIVATE-OTHER-STORE'
    @user.update_permission_overrides!(%w[settings.read])
    get ctrax_stock_index_path
    assert_response :redirect
  end

  private

  def save_connection
    patch pos_connection_path('ctrax'),
      params: { pos_connection: { vendor_approved: true, hourly_sync_enabled: true,
                                  credential_secret: @credentials } }
  end
end
