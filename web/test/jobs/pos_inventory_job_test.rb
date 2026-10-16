# frozen_string_literal: true

require 'test_helper'
class PosInventoryJobTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
    @location = Location.create!(source: 'ctrax', externalId: 'stock-pos-fixture/1', name: 'Stock fixture')
    @user = users(:regular_user)
    @display = PosDisplaySession.create!(user: @user, location: @location)
    @snapshot = CtraxStockSnapshot.create!(location: @location, api_origin: 'https://fixture.api.cannatrax.net', store_id: '1', records_json: [], captured_at: Time.current)
    PosSetting.create!(location: @location, stock_writes_enabled: true)
    PosConnection.create!(provider: 'ctrax', vendor_approved: true, credentials_json: { api_url: 'https://fixture.api.cannatrax.net', api_username: 'fixture', api_password: 'fixture-password' }.to_json)
    @checkout = PosCheckout.create!(location: @location, user: @user, pos_display_session: @display, cart_revision: 1, reference: SecureRandom.hex(16), tender: 'cash', status: 'paid', paid_at: Time.current, lines_json: [], subtotal_cents: 100, tax_cents: 0, tip_cents: 0, total_cents: 100)
    @allocation = PosStockAllocation.create!(location: @location, pos_checkout: @checkout, variant_id: '7', quantity: 2, status: 'pending')
    @client = mock
    Ctrax::Client.stubs(:new).returns(@client)
    @client.stubs(:use_store).with('1')
    @client.stubs(:stock).with('1').returns([{ 'id' => 7, 'store_stock' => { 'quantity' => 10 } }])
    @client.stubs(:inventory_adjustments).with('1', '7').returns([])
    Ctrax::StockSync.stubs(:call).returns(stores: 1, variants: 1)
  end
  teardown { Current.reset }
  test 'paid sale applies only its native quantity and a verified source response once' do
    @client.expects(:remove_stock).with('1', '7', quantity: 2, reference: @allocation.marker).once.returns('stock' => { 'store_id' => 1, 'product_variant_id' => 7, 'quantity' => 8 })
    PosInventoryJob.perform_now(@checkout.id)
    assert_equal 'applied', @allocation.reload.status
    assert_equal 10, @allocation.source_quantity_before
    PosInventoryJob.perform_now(@checkout.id)
    assert_equal 'applied', @allocation.reload.status
  end
  test 'lost write response never causes a second deduction' do
    @client.expects(:remove_stock).once.raises(Ctrax::Client::Error.new(:network))
    PosInventoryJob.perform_now(@checkout.id)
    assert_equal 'unknown', @allocation.reload.status
    PosInventoryJob.perform_now(@checkout.id)
    assert_equal 'unknown', @allocation.reload.status
  end
  test 'exact durable source marker can resolve a lost response without a new write' do
    @allocation.update!(status: 'unknown', submitted_at: 1.minute.ago)
    @client.stubs(:inventory_adjustments).returns([{ 'id' => 99, 'comments' => @allocation.marker, 'action' => 'remove', 'quantity' => 2 }])
    @client.expects(:remove_stock).never
    PosInventoryJob.perform_now(@checkout.id)
    assert_equal 'applied', @allocation.reload.status
    assert_equal '99', @allocation.source_adjustment_id
  end
  test 'unpaid sales disabled writes and another source origin cannot deduct stock' do
    @client.expects(:remove_stock).never
    @checkout.update!(status: 'ready')
    PosInventoryJob.perform_now(@checkout.id)
    @checkout.update!(status: 'paid')
    PosSetting.first.update!(stock_writes_enabled: false)
    PosInventoryJob.perform_now(@checkout.id)
    assert_equal 'pending', @allocation.reload.status
  end
end
