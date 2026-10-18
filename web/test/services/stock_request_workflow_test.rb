# frozen_string_literal: true

require 'test_helper'

class StockRequestWorkflowTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
    @actor = User.find_by!(email: 'admin@example.com')
    product = ShopifyProduct.create!(id: 'workflow-product', title: 'Workflow product', status: 'ACTIVE')
    @variant = ShopifyVariant.create!(productId: product.id, sku: 'FLOW-1', title: 'Stock widget')
    @source = Location.create!(source: 'shopify', externalId: 'workflow-source', name: 'Warehouse', active: true)
    @destination = Location.create!(source: 'shopify', externalId: 'workflow-destination', name: 'Shop', active: true)
    @level = InventoryLevel.create!(source: 'shopify', locationId: @source.id, shopifyVariantId: @variant.id, quantity: 10, available: 8)
    @target = InventoryLevel.create!(source: 'shopify', locationId: @destination.id, shopifyVariantId: @variant.id, quantity: 0, available: 0)
    @workflow = StockRequestWorkflow.new(actor: @actor)
  end

  teardown { Current.reset }

  test 'transfer reserves dispatches and accepts replay-safe partial receipts without mirror writes' do
    request = create_request
    assert_equal 'allocated', request.status
    assert_equal 4, request.source_pool.available_to_promise
    assert_equal 10, @level.reload.quantity
    assert_equal 0, @target.reload.quantity
    assert_equal 4, InventoryLevel.warehouse_quantities(tenant_id: Current.tenant_id, variant_ids: [@variant.id])[@variant.id]
    assert_raises(StockReservationService::ManagedHold) { StockReservationService.release(request.stock_reservation, actor: @actor.email) }
    assert_raises(StockRequestWorkflow::Error) { transition(request, 'dispatched') }
    assert_equal 'allocated', request.reload.status

    adjust = refresh(@level, quantity: 6, available: 4)
    token = SecureRandom.uuid
    transition(request, 'dispatched', token: token, confirmed: '1', adjusted_at: adjust.iso8601(6), reference: 'TRANSFER-SOURCE-1')
    assert_equal 'dispatched', request.status
    assert_equal 'released', request.stock_reservation.reload.status
    assert_equal 4, request.source_pool.available_to_promise
    assert_equal 4, InventoryWorkspace.new([@target]).rows.first[:incoming]
    transition(request, 'dispatched', token: token, confirmed: '1', adjusted_at: adjust.iso8601(6), reference: 'TRANSFER-SOURCE-1')
    assert_equal 2, request.events.count
    assert_raises(StockRequestWorkflow::Error) { transition(request, 'cancelled') }

    adjust = refresh(@target, quantity: 2, available: 2)
    token = SecureRandom.uuid
    transition(request, 'received', token: token, quantity: '2', confirmed: '1', adjusted_at: adjust.iso8601(6), reference: 'TRANSFER-RECEIPT-1')
    assert_equal 2, request.received_quantity
    assert_equal 'dispatched', request.status
    transition(request, 'received', token: token, quantity: '2', confirmed: '1', adjusted_at: adjust.iso8601(6), reference: 'TRANSFER-RECEIPT-1')
    assert_equal 2, request.received_quantity
    assert_equal 2, InventoryWorkspace.new([@target]).rows.first[:incoming]
    assert_raises(StockRequestWorkflow::Error) { transition(request, 'received', quantity: '3') }
    adjust = refresh(@target, quantity: 4, available: 4)
    transition(request, 'received', quantity: '2', confirmed: '1', adjusted_at: adjust.iso8601(6), reference: 'TRANSFER-RECEIPT-2')
    assert_equal 'completed', request.status
    assert_equal 4, request.received_quantity
    assert_equal 0, InventoryWorkspace.new([@target]).rows.first[:incoming]
    assert_equal 4, request.events.count
    assert_equal @actor.email, request.events.last.actor
    assert_equal 'TRANSFER-RECEIPT-2', request.events.last.reference
    assert_raises(ActiveRecord::ReadOnlyRecord) { request.events.last.destroy! }
    assert_equal 0, InventoryMovement.count
  end

  test 'backorder demand does not hold stock until allocation and fulfillment requires refreshed evidence' do
    request = create_request(kind: 'backorder', quantity: 6)
    assert_equal 'pending', request.status
    assert_nil request.stock_reservation
    assert_equal 6, InventoryWorkspace.new([@level]).rows.first[:demand]
    assert_equal 8, InventoryWorkspace.new([@level]).rows.first[:promise]
    transition(request, 'allocated')
    assert_equal 2, request.source_pool.available_to_promise
    assert_equal 0, InventoryWorkspace.new([@level]).rows.first[:demand]
    assert_raises(StockRequestWorkflow::Error) { transition(request, 'fulfilled', confirmed: '1', adjusted_at: Time.current.iso8601(6), reference: 'not refreshed') }
    assert_equal 'active', request.stock_reservation.reload.status
    adjust = refresh(@level, quantity: 4, available: 2)
    transition(request, 'fulfilled', confirmed: '1', adjusted_at: adjust.iso8601(6), reference: 'PICKUP-42')
    assert_equal 'completed', request.status
    assert_equal 6, request.received_quantity
    assert_equal 2, request.source_pool.available_to_promise
    assert_equal 4, @level.reload.quantity
  end

  test 'short stock and stale reads roll back requests and reservations atomically' do
    assert_no_difference ['StockRequest.count', 'StockReservation.count', 'StockRequestEvent.count'] do
      assert_raises(StockRequestWorkflow::Error) { create_request(quantity: 9) }
      @level.update!(updatedAt: 2.hours.ago)
      assert_raises(StockRequestWorkflow::Error) { create_request }
    end
    request = create_request(kind: 'backorder', quantity: 9)
    assert_raises(StockRequestWorkflow::Error) { transition(request, 'allocated') }
    assert_equal 'pending', request.reload.status
    assert_nil request.stock_reservation_id
  end

  test 'cancellation releases managed holds and retains its history' do
    request = create_request
    token = SecureRandom.uuid
    transition(request, 'cancelled', token: token)
    transition(request, 'cancelled', token: token)
    assert_equal 'cancelled', request.status
    assert_equal 8, request.source_pool.available_to_promise
    assert_equal 2, request.events.count
    assert_raises(StockRequestWorkflow::Error) { transition(request, 'dispatched') }
    pending = create_request(kind: 'backorder')
    transition(pending, 'cancelled')
    assert_equal 'cancelled', pending.status
    assert_equal 1, StockReservation.count
  end

  test 'creation and action tokens reject changed payloads and cross-request replays' do
    token = SecureRandom.uuid
    request = create_request(token: token)
    assert_equal request.id, create_request(token: token).id
    assert_raises(StockRequestWorkflow::Error) { create_request(token: token, quantity: 3) }
    assert_raises(StockRequestWorkflow::Error) { transition(request, 'cancelled', token: token) }
    second = create_request(kind: 'backorder')
    action_token = SecureRandom.uuid
    transition(second, 'cancelled', token: action_token)
    assert_raises(StockRequestWorkflow::Error) { transition(request, 'cancelled', token: action_token) }
    assert_equal 'allocated', request.reload.status
    assert_equal 1, StockReservation.count
  end

  test 'native identities locations source and tenants cannot be mixed' do
    assert_raises(StockRequestWorkflow::Error) { create_request(destination: @source.id) }
    foreign = Tenant.create!(name: 'Other inventory', subdomain: 'other-inventory-flow')
    foreign_location = Location.create!(tenant_id: foreign.id, source: 'shopify', externalId: 'foreign', name: 'Foreign')
    assert_raises(StockRequestWorkflow::Error) { create_request(destination: foreign_location.id) }
    request = create_request
    @source.update!(externalId: 'changed-native-location')
    adjust = refresh(@level, quantity: 6, available: 4)
    assert_raises(StockRequestWorkflow::Error) { transition(request, 'dispatched', confirmed: '1', adjusted_at: adjust.iso8601(6), reference: 'WRONG-LOCATION') }
    assert_equal 'active', request.stock_reservation.reload.status
    Current.tenant = foreign
    assert_raises(ActiveRecord::RecordNotFound) { transition(request, 'cancelled') }
    assert_raises(StockRequestWorkflow::Error) { StockRequestWorkflow.new(actor: @actor) }
  end

  test 'bad quantities references tokens evidence dates and future reads never progress a request' do
    [0, -1, '2.5', 'invalid', 2_147_483_648].each do |quantity|
      assert_raises(StockRequestWorkflow::Error) { create_request(quantity: quantity) }
    end
    assert_raises(StockRequestWorkflow::Error) { create_request(token: '') }
    request = create_request
    [nil, '', 'invalid', 1.day.ago.iso8601, 1.day.from_now.iso8601].each do |stamp|
      assert_raises(StockRequestWorkflow::Error) { transition(request, 'dispatched', confirmed: '1', adjusted_at: stamp, reference: 'ADJUST') }
    end
    assert_equal 'allocated', request.reload.status
    assert_equal 1, request.events.count
  end

  test 'warehouse holds and local allocations share capacity in both directions' do
    share = WarehouseShare.create!(name: 'Wholesale', token: SecureRandom.hex(24))
    cart = WarehouseCart.create!(tenant_id: Current.tenant_id, share_id: share.id, token: SecureRandom.hex(24), status: 'open')
    hold = WarehouseStockHold.create!(warehouse_cart: cart, variant_id: @variant.id, quantity: 6)
    assert_equal 2, InventoryWorkspace.new([@level]).rows.first[:promise]
    assert_raises(StockRequestWorkflow::Error) { create_request(quantity: 3) }
    request = create_request(quantity: 2)
    assert_equal 0, request.source_pool.available_to_promise
    assert_equal 0, InventoryLevel.warehouse_quantities(tenant_id: Current.tenant_id, variant_ids: [@variant.id])[@variant.id]
    hold.update!(status: 'released', release_reason: 'gateway_declined', released_at: Time.current)
    assert_equal 6, InventoryLevel.warehouse_quantities(tenant_id: Current.tenant_id, variant_ids: [@variant.id])[@variant.id]
    assert_equal 6, request.source_pool.available_to_promise
    other = Tenant.create!(name: 'Foreign warehouse', subdomain: 'foreign-warehouse-inventory')
    assert_equal 0, InventoryLevel.warehouse_quantities(tenant_id: other.id, variant_ids: [@variant.id])[@variant.id]
  end

  test 'signed mirror observations are preserved and incoming stock is never promised' do
    @target.update!(sourceQuantity: -3, quantity: 0, available: -3)
    create_request
    row = InventoryWorkspace.new([@target]).rows.first
    assert_equal(-3, row[:on_hand])
    assert_equal(-3, row[:available])
    assert_equal 0, row[:promise]
    assert_equal 0, row[:incoming]
  end

  private

  def create_request(kind: 'transfer', quantity: 4, token: SecureRandom.uuid, destination: @destination.id)
    attributes = { request_kind: kind, inventory_level_id: @level.id, quantity: quantity, reference: 'Move / order 42', due_on: Date.current.to_s }
    attributes[:destination_location_id] = destination if kind == 'transfer'
    @workflow.create(attributes: attributes, token: token)
  end

  def transition(request, event, token: SecureRandom.uuid, **attributes)
    @workflow.transition(request: request, action: event, token: token, **attributes)
  end

  def refresh(level, quantity:, available:)
    travel 2.seconds
    stamp = Time.current
    level.update!(quantity: quantity, available: available, updatedAt: stamp)
    stamp
  end
end
