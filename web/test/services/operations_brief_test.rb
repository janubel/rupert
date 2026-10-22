# frozen_string_literal: true

require 'test_helper'

class OperationsBriefTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
    Setting.where('key LIKE ?', 'operations_brief_%').delete_all
  end

  teardown do
    Core::OrderLine.delete_all
    Core::Order.delete_all
    SyncRun.delete_all
    StockAlert.delete_all
    Setting.where('key LIKE ?', 'operations_brief_%').delete_all
    Current.tenant = nil
  end

  test 'daily close publishes reproducible sales metrics once per day' do
    order = create_paid_order(gross_cents: 4200)
    Core::OrderLine.create!(
      tenant_id: Current.tenant_id,
      order: order,
      name: 'Honey Sticks',
      quantity: 2,
      line_cents: 4200
    )
    content = nil
    TeamChat::Notices.stubs(:notify).with do |message, *_|
      content = message
      true
    end.returns([true, 'OK'])

    assert OperationsBrief.publish!('daily_close')
    assert_includes content, '1 order(s)'
    assert_includes content, '$42.00'
    assert_includes content, 'Honey Sticks (2)'
    refute OperationsBrief.publish!('daily_close')
  end

  test 'failed publication is retried rather than marked complete' do
    create_paid_order(gross_cents: 4200)
    TeamChat::Notices.stubs(:notify).returns([false, 'relay unavailable'])

    assert_raises(RuntimeError) { OperationsBrief.publish!('morning') }
    assert_nil Setting.find_by(key: 'operations_brief_morning_last_period')
  end

  private

  def create_paid_order(gross_cents:)
    order = Core::Order.create!(
      tenant_id: Current.tenant_id,
      source: 'shopify',
      source_order_id: SecureRandom.hex(8),
      order_number: 'ORD-1',
      occurred_at: Time.current,
      channel: 'online',
      gross_cents: gross_cents
    )
    order.mark_paid!
    order
  end
end
