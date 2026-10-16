# frozen_string_literal: true

require 'test_helper'
class PosCheckoutTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
    @user = users(:regular_user)
    @location = Location.create!(source: 'ctrax', externalId: 'pos-fixture/1', name: 'POS fixture')
    @snapshot = CtraxStockSnapshot.create!(location: @location, api_origin: 'https://fixture.api.cannatrax.net', store_id: '1', captured_at: Time.current,
      records_json: [{ 'id' => '7', 'name' => 'Tea', 'product_name' => 'Tea', 'sku' => nil, 'price_cents' => 1005, 'tax_rate_mbp' => 600_000, 'quantity' => '2', 'manage_stock' => true, 'listed' => true }])
    PosConnection.create!(provider: 'ctrax', vendor_approved: true, credentials_json: { api_url: 'https://fixture.api.cannatrax.net', api_username: 'fixture', api_password: 'fixture-password' }.to_json)
    @setting = PosSetting.create!(location: @location, cash_enabled: true)
    @register = Sales::PosSession.create!(location: @location, user: @user, name: 'Front', opened_at: Time.current, opening_cash_cents: 5000)
    @display = PosDisplaySession.create!(user: @user, location: @location)
    publish(@display)
    Ctrax::StockSync.stubs(:call).returns(stores: 1, variants: 1)
  end
  teardown { Current.reset }

  test 'cash checkout records confirmed tip tax exact change native identity and one durable sale' do
    assert_equal :confirmed, @display.choose_tip!(revision: @display.cart_revision, choice: '10')
    checkout = prepare
    assert_equal 60, checkout.tax_cents
    assert_equal 101, checkout.tip_cents
    assert_equal 1166, checkout.total_cents
    Pos::Checkout.cash!(checkout, received: '20.00')
    assert checkout.reload.paid?
    assert_equal 834, checkout.change_cents
    assert_equal 1065, checkout.order.gross_cents
    assert_equal 101, checkout.order.tip_cents
    assert_equal 1166, checkout.order.payments.completed.sum(:amount_cents)
    assert_equal 0, checkout.order.balance_due_cents
    assert_equal '7', checkout.order.order_lines.first.source_variant_id
    assert_nil checkout.order.order_lines.first.sku
    assert_equal 6166, @register.reload.expected_cash_cents
    assert_equal 'pending', checkout.pos_stock_allocations.first.status
    Pos::Checkout.cash!(checkout.reload, received: '20.00')
    assert_equal checkout.id, prepare.id
    assert_equal 1, Core::Order.where(source: 'rupert_pos').count
    assert_equal 1, checkout.order.payments.count
  end

  test 'unconfirmed tip stale revision insufficient cash and unresolved checkout cannot complete' do
    assert_raises(Pos::Error) { prepare }
    @display.choose_tip!(revision: @display.cart_revision, choice: 'none')
    checkout = prepare
    assert_raises(Pos::Error) { Pos::Checkout.cash!(checkout, received: '1.00') }
    assert_not checkout.reload.paid?
    assert_empty Core::Order.where(source: 'rupert_pos')
    checkout.update!(status: 'unknown')
    assert_raises(Pos::Error) { Pos::Checkout.cancel!(checkout) }
    assert_raises(Pos::Error) { @display.publish!(@display.draft.merge('subtotal' => '1.00')) }
  end

  test 'price change invalidates confirmation before any payment or allocation' do
    @display.choose_tip!(revision: @display.cart_revision, choice: 'none')
    @snapshot.update!(records_json: @snapshot.records.map { |row| row.merge('price_cents' => 1200) })
    assert_raises(Pos::Error) { prepare }
    assert_not @display.reload.confirmed?
    assert_equal 1200, @display.draft['subtotal_cents']
    assert_empty PosCheckout.all
    assert_empty PosStockAllocation.all
  end

  test 'same native stock cannot be allocated to overlapping cashiers twice' do
    @display.choose_tip!(revision: @display.cart_revision, choice: 'none')
    first = prepare
    Pos::Checkout.cash!(first, received: '11')
    second = PosDisplaySession.create!(user: @user, location: @location)
    publish(second, quantity: 2)
    second.choose_tip!(revision: second.cart_revision, choice: 'none')
    assert_raises(Pos::Error) { Pos::Checkout.prepare!(display: second, tender: 'cash', register_id: @register.id) }
    assert_equal 1, PosCheckout.count
    assert_equal 1, PosStockAllocation.sum(:quantity)
  end

  test 'demo traverses confirmation cash receipt without real order or stock mutation' do
    demo = PosDisplaySession.create!(user: @user, location: @location, demo: true)
    publish(demo)
    demo.choose_tip!(revision: demo.cart_revision, choice: '15')
    checkout = Pos::Checkout.prepare!(display: demo, tender: 'cash', register_id: nil)
    Pos::Checkout.cash!(checkout, received: '20')
    assert checkout.paid?
    assert checkout.receipt[:demo]
    assert_empty Core::Order.where(source: 'rupert_pos')
    assert_empty PosStockAllocation.all
  end

  test 'closed registers and missing source taxes fail before payment' do
    @display.choose_tip!(revision: @display.cart_revision, choice: 'none')
    @register.settle!(counted_cents: 5000)
    assert_raises(ActiveRecord::RecordNotFound) { prepare }
    @register.reopen!
    @snapshot.update!(records_json: @snapshot.records.map { |row| row.merge('tax_rate_mbp' => nil) })
    assert_raises(Pos::Error) { prepare }
    assert_empty Core::Order.where(source: 'rupert_pos')
  end

  test 'foreign tenant registers cannot fund another workspace checkout' do
    @display.choose_tip!(revision: @display.cart_revision, choice: 'none')
    tenant = Tenant.create!(name: 'Other POS', subdomain: 'other-pos-checkout')
    register = Sales::PosSession.unscoped.create!(tenant_id: tenant.id, name: 'Private', opened_at: Time.current)
    assert_raises(ActiveRecord::RecordNotFound) { Pos::Checkout.prepare!(display: @display, tender: 'cash', register_id: register.id) }
    assert_empty PosCheckout.all
  end

  test 'an outstanding checkout blocks register close until it is cancelled' do
    @display.choose_tip!(revision: @display.cart_revision, choice: 'none')
    checkout = prepare
    assert_raises(Pos::Error) { @register.settle!(counted_cents: 5000) }
    assert_equal 'open', @register.reload.status
    Pos::Checkout.cancel!(checkout)
    assert_equal 'released', checkout.pos_stock_allocations.first.status
    @register.settle!(counted_cents: 5000)
    assert_equal 'closed', @register.reload.status
  end

  private

  def prepare = Pos::Checkout.prepare!(display: @display.reload, tender: 'cash', register_id: @register.id)

  def publish(display, quantity: 1)
    amount = (BigDecimal('10.05') * quantity).to_s('F')
    quote = { source: 'ctrax', currency_code: 'USD', preview: display.demo?, subtotal: amount,
      lines: [{ variant_id: '7', sku: nil, title: 'Tea', product_title: 'Tea', quantity: quantity, unit_price: '10.05', line_total: amount }] }
    Pos::Quote.decorate!(quote, @snapshot, demo: display.demo?)
    display.publish!(quote.deep_stringify_keys)
  end
end
