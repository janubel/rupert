# frozen_string_literal: true

require 'test_helper'
require_relative '../support/nmi_sandbox_fixture'

class NmiSandboxCheckoutIntegrationTest < ActionDispatch::IntegrationTest
  include NmiSandboxFixture
  setup do
    Current.tenant = tenants(:default_tenant)
    @user = users(:regular_user)
    @location = Location.create!(source: 'ctrax', externalId: 'nmi-integration/7', name: 'NMI fixture')
    @snapshot = CtraxStockSnapshot.create!(location: @location, api_origin: 'https://fixture.api.cannatrax.net', store_id: '7', captured_at: Time.current,
      records_json: [{ 'id' => '3', 'name' => 'Tea', 'product_name' => 'Tea', 'price_cents' => 1005, 'tax_rate_mbp' => 600_000, 'quantity' => '4', 'manage_stock' => true, 'listed' => true }])
    PosConnection.create!(provider: 'ctrax', vendor_approved: true, credentials_json: { api_url: @snapshot.api_origin, api_username: 'fixture', api_password: 'private-fixture' }.to_json)
    @setting = PosSetting.create!(location: @location, gateway_provider: 'nmi', gateway_id: '123', credentials_json: nmi_credentials, stock_writes_enabled: true)
    @register = Sales::PosSession.create!(location: @location, user: @user, name: 'Front', opened_at: Time.current)
    @display = PosDisplaySession.create!(user: @user, location: @location)
    prepare_nmi_fixture
    post login_path, params: { email: @user.email, password: 'password' }
    post verify_pos_setting_path(@location.id)
    assert_redirected_to pos_setting_path(@location.id)
    assert @setting.reload.verified_at
    @setting.update!(card_enabled: true)
    post quote_ctrax_pos_path(@location.id, display_id: @display.id), params: { items: [{ variant_id: '3', quantity: 1 }] }, as: :json
    assert_response :success
    @display.reload
    post customer_display_tip_path, params: { display_token: @display.display_token, cart_revision: @display.cart_revision, choice: '10' }, as: :json
    assert_response :success
    Ctrax::StockSync.stubs(:call).returns(stores: 1, variants: 1)
    post pos_checkouts_path, params: { display_id: @display.id, tender: 'card', register_id: @register.id, total_cents: 1, tip_cents: 90000 }, as: :json
    assert_response :success
    @checkout = PosCheckout.last
  end
  teardown { Current.reset }

  test 'private customer sandbox checkout uses server totals and leaves live records untouched' do
    get pos_setting_path(@location.id)
    assert_response :success
    assert_includes response.body, 'NMI live payments are disabled'
    assert_not_includes response.body, 'sandbox-private-fixture'
    assert_not_includes @setting.attributes_before_type_cast['credentials_json'], 'sandbox-private-fixture'
    customer = ActionDispatch::Integration::Session.new(Rails.application)
    customer.get customer_payment_config_path(display_token: @display.display_token)
    assert_equal 200, customer.response.status
    config = customer.response.parsed_body
    assert_equal true, config['sandbox']
    assert_equal 'nmi', config['provider']
    assert_equal 1166, config['total_cents']
    assert_equal 'sandbox-public-fixture', config['tokenization_key']
    assert_equal Pos::NmiGateway::SCRIPT_URL, config['script_url']
    assert_not_includes customer.response.body, 'sandbox-private-fixture'
    assert_not_includes customer.response.body, 'Sandbox Company'
    assert_enqueued_jobs 0 do
      customer.post customer_pay_path, params: { display_token: @display.display_token, checkout_reference: @checkout.reference, payment_nonce: 'integration-card-token', total_cents: 1 }, as: :json
    end
    assert_equal 200, customer.response.status
    assert_equal 'paid', customer.response.parsed_body['status']
    assert_equal true, customer.response.parsed_body['sandbox']
    assert_empty Core::Order.where(source: 'rupert_pos')
    assert_empty PosStockAllocation.all
    assert_equal 0, @register.reload.card_sales_cents.to_i
    get pos_checkout_path(@checkout)
    assert_response :success
    assert_includes response.body, 'Sandbox receipt'
    assert_equal 1, @nmi_sales
  end

  test 'stale checkout reference and raw card parameters cannot trigger a charge' do
    post customer_pay_path, params: { display_token: @display.display_token, checkout_reference: 'old-checkout', payment_nonce: 'integration-card-token' }, as: :json
    assert_response :unprocessable_entity
    post customer_pay_path, params: { display_token: @display.display_token, checkout_reference: @checkout.reference, ccnumber: '4111111111111111', cvv: '123' }, as: :json
    assert_response :unprocessable_entity
    assert_equal 0, @nmi_sales
    assert_empty PosPaymentAttempt.all
  end

  test 'NMI production cannot be selected or enabled and credentials stay encrypted' do
    patch pos_setting_path(@location.id), params: { pos_setting: { environment: 'production', card_enabled: true, lock_version: @setting.reload.lock_version } }
    assert_response :unprocessable_entity
    assert_equal 'sandbox', @setting.reload.environment
    assert_equal 'nmi', @setting.gateway_provider
    assert_equal 0, @nmi_sales
  end

  test 'switching provider clears incompatible keys and requires a new check' do
    patch pos_setting_path(@location.id), params: { pos_setting: { gateway_provider: 'authorize_net', lock_version: @setting.reload.lock_version } }
    assert_redirected_to pos_setting_path(@location.id)
    assert_empty @setting.reload.credentials
    assert_not @setting.card_enabled
    assert_nil @setting.verified_at
    assert_nil @setting.public_client_key
  end
end
