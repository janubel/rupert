# frozen_string_literal: true

require 'test_helper'

class PurchaseReceivingTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
    @actor = User.find_by!(email: 'admin@example.com')
    vendor = Purchasing::Vendor.create!(name: 'Inventory vendor')
    @order = Purchasing::PurchaseOrder.create!(vendor: vendor, order_number: 'DELIVERY-42')
    @line = @order.lines.create!(name: 'Widget', quantity: 10, unit_cost_cents: 125, received_quantity: 0)
    @other = @order.lines.create!(name: 'Other widget', quantity: 2, unit_cost_cents: 100, received_quantity: 0)
    @order.place_order!
  end

  teardown { Current.reset }

  test 'partial cumulative deliveries retain deltas and replay without duplicate receiving' do
    token = SecureRandom.uuid
    delivery = receive({ @line.id => '3', @other.id => '0' }, token: token)
    assert_equal 3, @line.reload.received_quantity
    assert_equal 'ordered', @order.reload.status
    assert_equal({ @line.id.to_s => 3, @other.id.to_s => 0 }, delivery.quantities_json)
    assert_equal delivery.id, receive({ @line.id => '3', @other.id => '0' }, token: token).id
    assert_equal 1, @order.deliveries.count
    receive({ @line.id => '10', @other.id => '2' })
    assert_equal 'received', @order.reload.status
    assert_equal 10, @line.reload.received_quantity
    assert_equal 2, @order.deliveries.count
    assert_equal @actor.email, delivery.actor
    assert_raises(ActiveRecord::ReadOnlyRecord) { delivery.update!(actor: 'changed') }
  end

  test 'negative fractional excessive backwards and foreign line quantities are refused atomically' do
    receive({ @line.id => '3' })
    [-1, '2.5', 'oops', 11, 2].each do |quantity|
      assert_raises(PurchaseReceiving::Error) { receive({ @other.id => '1', @line.id => quantity.to_s }) }
      assert_equal 0, @other.reload.received_quantity
      assert_equal 3, @line.reload.received_quantity
    end
    assert_raises(PurchaseReceiving::Error) { receive({ '9999999' => '1' }) }
    assert_equal 1, @order.deliveries.count
  end

  test 'draft cancelled and completed orders reject new receiving and changed token replays' do
    token = SecureRandom.uuid
    receive({ @line.id => '3' }, token: token)
    assert_raises(PurchaseReceiving::Error) { receive({ @line.id => '4' }, token: token) }
    @order.cancel!
    assert_raises(PurchaseReceiving::Error) { receive({ @line.id => '4' }) }
    assert_equal 3, @line.reload.received_quantity
  end

  test 'tenant and role isolation apply even to preloaded orders' do
    reader = User.create!(email: 'receiving-reader@example.com', password: 'password123', role: 'reader', tenant: Current.tenant)
    assert_raises(PurchaseReceiving::Error) { PurchaseReceiving.call(order: @order, totals: { @line.id => '1' }, token: SecureRandom.uuid, actor: reader) }
    Current.tenant = Tenant.create!(name: 'Other receiving', subdomain: 'other-receiving')
    assert_raises(PurchaseReceiving::Error) { receive({ @line.id => '1' }) }
  end

  private

  def receive(totals, token: SecureRandom.uuid)
    PurchaseReceiving.call(order: @order, totals: totals, token: token, actor: @actor)
  end
end
