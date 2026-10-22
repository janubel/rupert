# frozen_string_literal: true

require 'test_helper'

class FulfillmentMonitorTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
    Setting.where(key: FulfillmentMonitor::SIGNATURE_KEY).delete_all
  end

  teardown do
    Core::Fulfillment.delete_all
    Core::Order.delete_all
    Setting.where(key: FulfillmentMonitor::SIGNATURE_KEY).delete_all
    Current.tenant = nil
  end

  test 'announces overdue paid online orders once' do
    order = create_order(occurred_at: 25.hours.ago)
    order.mark_paid!
    content = nil
    TeamChat::Notices.stubs(:notify).with do |message, *_|
      content = message
      true
    end.returns([true, 'OK'])

    assert_equal 1, FulfillmentMonitor.check!
    assert_includes content, order.display_number
    assert_includes content, '$25.00'
    assert_equal 0, FulfillmentMonitor.check!
  end

  test 'ignores recent, point-of-sale, and fulfilled orders' do
    recent = create_order(occurred_at: 2.hours.ago)
    recent.mark_paid!
    pos = create_order(occurred_at: 25.hours.ago, channel: 'pos')
    pos.mark_paid!
    fulfilled = create_order(occurred_at: 25.hours.ago)
    fulfilled.mark_paid!
    Core::Fulfillment.create!(
      order: fulfilled,
      tenant_id: Current.tenant_id,
      source: 'shopify',
      source_fulfillment_id: SecureRandom.hex(8),
      status: 'fulfilled'
    )
    shipped = create_order(occurred_at: 25.hours.ago)
    shipped.mark_paid!
    shipped.update!(fulfillment_status: 'shipped')

    TeamChat::Notices.expects(:notify).never
    assert_equal 0, FulfillmentMonitor.check!
  end

  test 'does not save the signature when publishing fails' do
    order = create_order(occurred_at: 25.hours.ago)
    order.mark_paid!
    TeamChat::Notices.stubs(:notify).returns([false, 'relay unavailable'])

    assert_raises(RuntimeError) { FulfillmentMonitor.check! }
    assert_nil Setting.find_by(key: FulfillmentMonitor::SIGNATURE_KEY)
  end

  private

  def create_order(occurred_at:, channel: 'online')
    Core::Order.create!(
      tenant_id: Current.tenant_id,
      source: 'shopify',
      source_order_id: SecureRandom.hex(8),
      order_number: "ORD-#{SecureRandom.hex(3)}",
      occurred_at: occurred_at,
      channel: channel,
      gross_cents: 2500
    )
  end
end
