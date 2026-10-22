# frozen_string_literal: true

require 'test_helper'

class StockReservationsTest < ActionDispatch::IntegrationTest
  setup do
    Current.tenant = tenants(:default_tenant)
    product = ShopifyProduct.create!(id: 'reservation-ui-product', title: 'Reservation product')
    @variant = ShopifyVariant.create!(productId: product.id, sku: 'HOLD-UI', title: 'Reservation widget')
    location = Location.create!(source: 'shopify', externalId: 'hold-ui', name: 'Shopify warehouse')
    @level = InventoryLevel.create!(source: 'shopify', locationId: location.id,
      shopifyVariantId: @variant.id, quantity: 10, available: 8)
    post login_path, params: { email: 'admin@example.com', password: 'password' }
  end

  teardown { Current.reset }

  test 'operator creates views and releases a reservation without mirror writes' do
    get new_stock_reservation_path
    assert_response :success
    assert_select 'h1', 'Add reservation'
    assert_select "option[value='#{@level.id}']", /available-to-promise: 8/
    assert_select "input[name='stock_reservation[request_token]']"
    token = css_select("input[name='stock_reservation[request_token]']").first['value']

    post stock_reservations_path, params: reservation_payload(token)
    hold = StockReservation.last
    assert_redirected_to stock_reservations_path
    assert_equal 'admin@example.com', hold.created_by
    assert_equal 'Pickup order 42', hold.reference
    assert_equal 3, hold.quantity
    assert_equal 8, @level.reload.available
    assert_equal 10, @level.quantity

    get stock_reservations_path
    assert_response :success
    assert_select 'td', 'Pickup order 42'
    assert_select 'td', /Reservation widget/
    assert_select 'td', 'Active'
    get new_stock_reservation_path, params: { q: 'HOLD-UI' }
    assert_select "option[value='#{@level.id}']", /local holds: 3, available-to-promise: 5/

    post stock_reservations_path, params: reservation_payload(token)
    assert_redirected_to stock_reservations_path
    assert_equal 1, StockReservation.count
    post release_stock_reservation_path(hold)
    assert_redirected_to stock_reservations_path
    assert_equal 'released', hold.reload.status
    post release_stock_reservation_path(hold)
    assert_equal 1, StockReservation.count
  end

  test 'invalid quantity renders errors and retains the request token' do
    token = SecureRandom.uuid
    post stock_reservations_path, params: reservation_payload(token, quantity: '9')
    assert_response :unprocessable_entity
    assert_select '[role=alert]', /8 units available/
    assert_select "input[name='stock_reservation[request_token]'][value='#{token}']"
    assert_equal 0, StockReservation.count
    post stock_reservations_path, params: reservation_payload(token, quantity: '2.5')
    assert_response :unprocessable_entity
    assert_select '[role=alert]', /must be an integer/
    assert_equal 0, StockReservation.count
  end

  test 'readers can view reservations but cannot create or release holds' do
    Current.tenant = tenants(:default_tenant)
    hold = StockReservationService.reserve(inventory_level_id: @level.id,
      attributes: { quantity: 2, reference: 'Existing' }, actor: 'admin@example.com')
    reader = User.create!(email: 'reservation-reader@example.com', password: 'password123',
      role: 'reader', tenant: tenants(:default_tenant))
    delete logout_path
    post login_path, params: { email: reader.email, password: 'password123' }
    get stock_reservations_path
    assert_response :success
    assert_select "a[href='#{new_stock_reservation_path}']", count: 0
    get new_stock_reservation_path
    assert_response :redirect
    post stock_reservations_path, params: reservation_payload(SecureRandom.uuid)
    assert_response :redirect
    post release_stock_reservation_path(hold)
    assert_response :redirect
    Current.tenant = tenants(:default_tenant)
    assert_equal 'active', hold.reload.status
    assert_equal 1, StockReservation.count
  end

  test 'write-only overrides cannot expose inventory without read permission' do
    Current.tenant = tenants(:default_tenant)
    hold = StockReservationService.reserve(inventory_level_id: @level.id,
      attributes: { quantity: 2, reference: 'Existing' }, actor: 'admin@example.com')
    employee = User.create!(email: 'write-only-reservations@example.com', password: 'password123',
      role: 'manager', tenant: tenants(:default_tenant))
    employee.update_permission_overrides!(['inventory.write'])
    delete logout_path
    post login_path, params: { email: employee.email, password: 'password123' }
    get stock_reservations_path
    assert_response :redirect
    get new_stock_reservation_path
    assert_response :redirect
    refute_includes response.body, 'Reservation widget'
    post stock_reservations_path, params: reservation_payload(SecureRandom.uuid)
    assert_response :redirect
    post release_stock_reservation_path(hold)
    assert_response :redirect
    Current.tenant = tenants(:default_tenant)
    assert_equal 'active', hold.reload.status
    assert_equal 1, StockReservation.count
  end

  test 'create requires the form request token' do
    payload = reservation_payload(SecureRandom.uuid)
    payload[:stock_reservation].delete(:request_token)
    post stock_reservations_path, params: payload
    assert_response :bad_request
    assert_equal 0, StockReservation.count
  end

  test 'foreign pool and reservation ids are inaccessible and hidden in selectors' do
    other = Tenant.create!(name: 'Other', subdomain: 'other-hold-ui')
    Current.tenant = other
    product = ShopifyProduct.create!(id: 'reservation-ui-foreign-product', title: 'Foreign product')
    variant = ShopifyVariant.create!(productId: product.id, sku: 'SECRET', title: 'Foreign widget')
    location = Location.create!(source: 'shopify', externalId: 'foreign-hold', name: 'Secret location')
    level = InventoryLevel.create!(source: 'shopify', locationId: location.id,
      shopifyVariantId: variant.id, quantity: 10, available: 10)
    hold = StockReservationService.reserve(inventory_level_id: level.id,
      attributes: { quantity: 1, reference: 'Secret order' }, actor: 'other@example.com')

    get new_stock_reservation_path
    assert_response :success
    assert_select "option[value='#{level.id}']", count: 0
    get stock_reservations_path
    assert_select 'td', text: 'Secret order', count: 0
    post stock_reservations_path, params: reservation_payload(SecureRandom.uuid, inventory_level_id: level.id)
    assert_response :not_found
    post release_stock_reservation_path(hold)
    assert_response :not_found
  end

  private

  def reservation_payload(token, **overrides)
    { stock_reservation: { inventory_level_id: @level.id, quantity: '3', reference: 'Pickup order 42',
      request_token: token }.merge(overrides) }
  end
end
