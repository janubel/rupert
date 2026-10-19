# frozen_string_literal: true

require 'test_helper'

class InventoryExecutionTest < ActionDispatch::IntegrationTest
  setup do
    Current.tenant = tenants(:default_tenant)
    product = ShopifyProduct.create!(id: 'inventory-execution-product', title: 'Execution product', status: 'ACTIVE')
    @variant = ShopifyVariant.create!(productId: product.id, sku: 'EXEC-UI', title: 'Execution widget')
    @source = Location.create!(source: 'shopify', externalId: 'execution-source', name: 'Warehouse', active: true)
    @target = Location.create!(source: 'shopify', externalId: 'execution-target', name: 'Retail', active: true)
    @level = InventoryLevel.create!(source: 'shopify', locationId: @source.id, shopifyVariantId: @variant.id, quantity: 10, available: 8)
    InventoryLevel.create!(source: 'shopify', locationId: @target.id, shopifyVariantId: @variant.id, quantity: 0, available: 0)
    post login_path, params: { email: 'admin@example.com', password: 'password' }
  end

  teardown { Current.reset }

  test 'inventory workspace filters and exports pools and links its workflows' do
    get workspace_inventory_index_path
    assert_response :success
    assert_select 'h1', 'Inventory'
    assert_select 'a[href=?]', stock_requests_path(kind: 'transfer'), text: 'Transfers'
    assert_select 'a[href=?]', stock_requests_path(kind: 'backorder'), text: 'Backorders'
    assert_select 'td', text: /Execution widget/, count: 2
    get workspace_inventory_index_path, params: { location_id: @source.id, q: 'EXEC-UI', sort: 'low' }
    assert_select 'td', text: /Execution widget/, count: 1
    get workspace_inventory_index_path(format: :csv), params: { location_id: @source.id, q: 'EXEC-UI' }
    assert_response :success
    rows = CSV.parse(response.body, headers: true)
    assert_equal 1, rows.size
    assert_equal '8', rows.first['Available to promise']
    assert_equal @variant.id, rows.first['Native ID']
  end

  test 'transfer form errors creation view cancellation and replay work end to end' do
    get new_stock_request_path, params: { kind: 'transfer', inventory_level_id: @level.id }
    assert_response :success
    token = css_select("input[name='request_token']").first['value']
    post stock_requests_path, params: payload(token, quantity: '99')
    assert_response :unprocessable_entity
    assert_select '[role=alert]', /8 units available/
    post stock_requests_path, params: payload(token)
    record = StockRequest.last
    assert_redirected_to stock_request_path(record)
    follow_redirect!
    assert_select 'h1', 'UI transfer 42'
    assert_select 'h2', 'Record dispatch'
    assert_select "input[name='confirmed'][required]"
    post stock_requests_path, params: payload(token)
    assert_equal 1, StockRequest.count
    get stock_reservations_path
    assert_select "a[href='#{stock_request_path(record)}']", /Transfer/
    assert_select "form[action='#{release_stock_reservation_path(record.stock_reservation)}']", count: 0
    post release_stock_reservation_path(record.stock_reservation)
    assert_redirected_to stock_reservations_path
    assert_equal 'active', record.stock_reservation.reload.status
    post transition_stock_request_path(record), params: { event: 'cancelled', request_token: SecureRandom.uuid }
    assert_redirected_to stock_request_path(record)
    assert_equal 'cancelled', record.reload.status
    get stock_requests_path, params: { kind: 'transfer' }
    assert_select 'td', 'Cancelled'
  end

  test 'reader and write-only access cannot mutate or expose restricted stock' do
    Current.tenant = tenants(:default_tenant)
    reader = User.create!(email: 'inventory-execution-reader@example.com', password: 'password123', role: 'reader', tenant: Current.tenant)
    delete logout_path
    post login_path, params: { email: reader.email, password: 'password123' }
    get workspace_inventory_index_path
    assert_response :success
    get stock_requests_path
    assert_response :success
    get new_stock_request_path
    assert_response :redirect
    post stock_requests_path, params: payload(SecureRandom.uuid)
    assert_response :redirect
    Current.tenant = tenants(:default_tenant)
    reader.update_permission_overrides!(['inventory.write'])
    get workspace_inventory_index_path
    assert_response :redirect
    get stock_requests_path
    assert_response :redirect
    assert_equal 0, StockRequest.count
  end

  test 'purchase delivery UI records partial receipts and rejects stale draft edits' do
    Current.tenant = tenants(:default_tenant)
    vendor = Purchasing::Vendor.create!(name: 'Receiving vendor')
    order = Purchasing::PurchaseOrder.create!(vendor: vendor, order_number: 'RECEIVING-UI')
    line = order.lines.create!(name: 'Receiving widget', quantity: 5, unit_cost_cents: 100, received_quantity: 0)
    post place_order_purchasing_purchase_order_path(order)
    get purchasing_purchase_order_path(order)
    assert_response :success
    assert_select 'h3', 'Receive goods'
    token = css_select("input[name='request_token']").first['value']
    post receive_purchasing_purchase_order_path(order), params: { received: { line.id => '2' }, request_token: token }
    assert_redirected_to purchasing_purchase_order_path(order)
    assert_equal 2, line.reload.received_quantity
    post receive_purchasing_purchase_order_path(order), params: { received: { line.id => '2' }, request_token: token }
    assert_equal 1, order.deliveries.count
    patch purchasing_purchase_order_path(order), params: { purchasing_purchase_order: { order_number: 'STALE-EDIT' } }
    assert_equal 'RECEIVING-UI', order.reload.order_number
    get purchasing_purchase_order_path(order)
    assert_select 'h2', 'Delivery history'
    assert_select 'p', /Delivery #/
  end

  test 'foreign inventory requests and source pools cannot be accessed' do
    Current.tenant = Tenant.create!(name: 'Other UI inventory', subdomain: 'other-ui-inventory')
    product = ShopifyProduct.create!(id: 'foreign-inventory-ui', title: 'Secret product', status: 'ACTIVE')
    variant = ShopifyVariant.create!(productId: product.id, title: 'Secret variant')
    location = Location.create!(source: 'shopify', externalId: 'secret', name: 'Secret warehouse')
    level = InventoryLevel.create!(source: 'shopify', locationId: location.id, shopifyVariantId: variant.id, quantity: 10, available: 10)
    actor = User.create!(tenant: Current.tenant, email: 'foreign-inventory-ui@example.com', role: 'admin', password: 'password123')
    record = StockRequestWorkflow.new(actor: actor).create(attributes: { request_kind: 'backorder', inventory_level_id: level.id, quantity: 1, reference: 'Secret demand' }, token: SecureRandom.uuid)
    get stock_request_path(record)
    assert_response :not_found
    post transition_stock_request_path(record), params: { event: 'allocated', request_token: SecureRandom.uuid }
    assert_response :not_found
    get workspace_inventory_index_path
    assert_not_includes response.body, 'Secret variant'
    post stock_requests_path, params: payload(SecureRandom.uuid, inventory_level_id: level.id)
    assert_response :not_found
  end

  private

  def payload(token, **attributes)
    { request_token: token, stock_request: { request_kind: 'transfer', inventory_level_id: @level.id, destination_location_id: @target.id,
      quantity: '3', reference: 'UI transfer 42', due_on: '' }.merge(attributes) }
  end
  test 'legacy mirror quantities are never labelled as native on hand' do
    get workspace_inventory_index_path, params: { q: 'EXEC-UI', location_id: @source.id }
    assert_response :success
    assert_select 'th', text: 'Mirror quantity'
    assert_select 'th', text: 'Mirror on hand', count: 0
    assert_includes response.body, 'Shopify legacy mirror quantity is available stock'
    get workspace_inventory_index_path(format: :csv), params: { q: 'EXEC-UI', location_id: @source.id }
    rows = CSV.parse(response.body, headers: true)
    assert_includes rows.headers, 'Mirror quantity'
    refute_includes rows.headers, 'Mirror on hand'
  end
end
