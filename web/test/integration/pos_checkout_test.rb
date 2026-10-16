# frozen_string_literal: true

require 'test_helper'

class PosCheckoutIntegrationTest < ActionDispatch::IntegrationTest
  setup do
    Current.tenant = tenants(:default_tenant)
    @user = users(:regular_user)
    @location = Location.create!(source: 'ctrax', externalId: 'fixture/7', name: 'Checkout fixture')
    @snapshot = CtraxStockSnapshot.create!(location: @location, api_origin: 'https://fixture.api.cannatrax.net', store_id: '7', captured_at: Time.current,
      records_json: [{ 'id' => '3', 'name' => 'Tea', 'product_name' => 'Tea', 'price_cents' => 1005, 'tax_rate_mbp' => 600_000, 'quantity' => '4', 'manage_stock' => true, 'listed' => true }])
    PosConnection.create!(provider: 'ctrax', vendor_approved: true, credentials_json: { api_url: @snapshot.api_origin, api_username: 'fixture', api_password: 'private-fixture' }.to_json)
    PosSetting.create!(location: @location, cash_enabled: true)
    @register = Sales::PosSession.create!(location: @location, user: @user, name: 'Front', opened_at: Time.current)
    @display = PosDisplaySession.create!(user: @user, location: @location)
    post login_path, params: { email: @user.email, password: 'password' }
    quote_and_confirm
    Ctrax::StockSync.stubs(:call).returns(stores: 1, variants: 1)
  end
  teardown { Current.reset }

  test 'cash end to end ignores submitted amounts and issues one receipt with private confirmed tip' do
    post pos_checkouts_path, params: { display_id: @display.id, tender: 'cash', register_id: @register.id, cash_received: '20', total_cents: 1, tip_cents: 90000 }, as: :json
    assert_response :success
    assert_equal 1166, response.parsed_body['total_cents']
    assert_equal 101, response.parsed_body['tip_cents']
    assert_equal 834, response.parsed_body['change_cents']
    checkout = PosCheckout.last
    get pos_checkout_path(checkout)
    assert_response :success
    assert_includes response.body, 'Receipt · Paid'
    assert_includes response.body, 'Stock updates'
    assert_select 'strong', '$11.66'
    customer = ActionDispatch::Integration::Session.new(Rails.application)
    customer.get customer_display_state_path(display_token: @display.display_token)
    assert_equal 'paid', customer.response.parsed_body.dig('checkout', 'status')
    assert_equal 101, customer.response.parsed_body.dig('checkout', 'tip_cents')
    post pos_checkouts_path, params: { display_id: @display.id, tender: 'cash', register_id: @register.id, cash_received: '20' }, as: :json
    assert_response :success
    assert_equal 1, PosCheckout.count
    assert_equal 1, Core::Order.where(source: 'rupert_pos').count
  end

  test 'insufficient cash allocates nothing and no public token permits another cashier checkout' do
    post pos_checkouts_path, params: { display_id: @display.id, tender: 'cash', register_id: @register.id, cash_received: '1' }, as: :json
    assert_response :unprocessable_entity
    assert_empty PosCheckout.all
    assert_empty PosStockAllocation.all
    other = User.create!(tenant: @user.tenant, email: 'private-cashier@example.test', password: 'password', role: 'cashier')
    foreign = PosDisplaySession.create!(user: other, location: @location)
    post pos_checkouts_path, params: { display_id: foreign.id, tender: 'cash', cash_received: '20' }, as: :json
    assert_response :not_found
  end

  test 'demo card completes anonymously without canonical payment or stock effects and rejects expired pairing' do
    @display.reload.update!(demo: true)
    quote_and_confirm
    post pos_checkouts_path, params: { display_id: @display.id, tender: 'card' }, as: :json
    assert_response :success
    customer = ActionDispatch::Integration::Session.new(Rails.application)
    customer.get customer_payment_config_path(display_token: @display.display_token)
    assert_equal({ 'demo' => true, 'total_cents' => 1166 }, customer.response.parsed_body)
    customer.post customer_pay_path, params: { display_token: @display.display_token }, as: :json
    assert_equal 200, customer.response.status
    assert_equal 'paid', customer.response.parsed_body['status']
    assert_empty Core::Order.where(source: 'rupert_pos')
    assert_empty PosStockAllocation.all
    assert_empty PosPaymentAttempt.all
    @display.reload.update!(expires_at: 1.minute.ago)
    customer.post customer_pay_path, params: { display_token: @display.display_token }, as: :json
    assert_equal 410, customer.response.status
  end

  test 'a paid checkout cannot be cancelled' do
    post pos_checkouts_path, params: { display_id: @display.id, tender: 'cash', register_id: @register.id, cash_received: '20' }, as: :json
    checkout = PosCheckout.last
    post cancel_pos_checkout_path(checkout), as: :json
    assert_response :unprocessable_entity
    assert checkout.reload.paid?
  end

  test 'gateway secrets remain encrypted and absent from setup and customer configuration' do
    setting = PosSetting.first
    setting.update!(gateway_id: '123', credentials_json: { api_login_id: 'fixture-login', transaction_key: 'fixture-key' }.to_json)
    setting.update!(verified_at: Time.current, public_client_key: 'public-client-fixture')
    setting.update!(card_enabled: true)
    get pos_setting_path(@location.id)
    assert_response :success
    assert_not_includes response.body, 'fixture-key'
    assert_not_includes setting.attributes_before_type_cast['credentials_json'], 'fixture-key'
    post pos_checkouts_path, params: { display_id: @display.id, tender: 'card', register_id: @register.id }, as: :json
    assert_response :success
    get customer_payment_config_path(display_token: @display.display_token)
    assert_response :success
    assert_equal 'public-client-fixture', response.parsed_body['client_key']
    assert_equal 'https://jstest.authorize.net/v3/AcceptUI.js', response.parsed_body['script_url']
    assert_not_includes response.body, 'fixture-key'
    PosCheckout.last.update!(status: 'unknown')
    patch pos_setting_path(@location.id), params: { pos_setting: { gateway_id: '456', lock_version: setting.reload.lock_version } }
    assert_response :unprocessable_entity
    assert_equal '123', setting.reload.gateway_id
    assert setting.card_enabled
  end

  test 'cashiers cannot configure payment credentials' do
    cashier = User.create!(tenant: @user.tenant, email: 'limited-cashier@example.test', password: 'password', role: 'cashier')
    delete logout_path
    post login_path, params: { email: cashier.email, password: 'password' }
    get pos_setting_path(@location.id)
    assert_redirected_to root_path
    assert_not_includes response.body, "Gateway ID"
  end

  private

  def quote_and_confirm
    post quote_ctrax_pos_path(@location.id, display_id: @display.id), params: { items: [{ variant_id: '3', quantity: 1 }] }, as: :json
    assert_response :success
    @display.reload
    post customer_display_tip_path, params: { display_token: @display.display_token, cart_revision: @display.cart_revision, choice: '10' }, as: :json
    assert_response :success
  end
end
