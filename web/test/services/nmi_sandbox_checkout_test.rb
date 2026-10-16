# frozen_string_literal: true

require 'test_helper'
require_relative '../support/nmi_sandbox_fixture'

class NmiSandboxCheckoutTest < ActiveSupport::TestCase
  include NmiSandboxFixture
  setup do
    Current.tenant = tenants(:default_tenant)
    @user = users(:regular_user)
    @location = Location.create!(source: 'ctrax', externalId: 'nmi-fixture/1', name: 'NMI sandbox fixture')
    @display = PosDisplaySession.create!(user: @user, location: @location)
    @register = Sales::PosSession.create!(location: @location, user: @user, name: 'Sandbox', opened_at: Time.current)
    @setting = PosSetting.create!(location: @location, gateway_provider: 'nmi', gateway_id: '123', credentials_json: nmi_credentials)
    @setting.update!(verified_at: Time.current)
    @setting.update!(card_enabled: true)
    @checkout = PosCheckout.create!(location: @location, user: @user, pos_display_session: @display, pos_session: @register,
      cart_revision: 1, reference: SecureRandom.hex(16), tender: 'card', gateway_provider: 'nmi',
      gateway_fingerprint: @setting.payment_fingerprint, gateway_id: '123', environment: 'sandbox',
      lines_json: [], subtotal_cents: 1005, tax_cents: 60, tip_cents: 101, total_cents: 1166)
    prepare_nmi_fixture
  end
  teardown { Current.reset }

  test 'approval and replay issue one sandbox receipt without revenue or stock effects' do
    before_register = @register.attributes
    Pos::CardPayment.call(@checkout, nonce: 'test-token-approved')
    assert @checkout.reload.paid?
    assert @checkout.receipt[:sandbox]
    assert_equal before_register, @register.reload.attributes
    assert_empty Core::Order.where(source: 'rupert_pos')
    assert_empty PosStockAllocation.all
    assert_nil @checkout.order_id
    Pos::CardPayment.call(@checkout, nonce: 'test-token-approved')
    assert_equal 1, @nmi_sales
    assert_equal 1, PosPaymentAttempt.count
    assert_equal '12345', PosPaymentAttempt.first.transaction_id
    assert_not_includes PosPaymentAttempt.first.attributes.to_json, 'test-token-approved'
  end

  test 'decline permits only a fresh token' do
    @nmi_mode = :declined
    Pos::CardPayment.call(@checkout, nonce: 'test-token-declined')
    assert_equal 'declined', @checkout.reload.status
    assert_raises(Pos::Error) { Pos::CardPayment.call(@checkout, nonce: 'test-token-declined') }
    @nmi_mode = :approved
    Pos::CardPayment.call(@checkout, nonce: 'test-token-new-card')
    assert @checkout.reload.paid?
    assert_equal 2, @nmi_sales
  end

  test 'lost response persists unknown and reads recover it without charging again' do
    @nmi_mode = :timeout
    assert_raises(Pos::Error) { Pos::CardPayment.call(@checkout, nonce: 'test-token-timeout') }
    assert_equal 'unknown', @checkout.reload.status
    Pos::CardPayment.call(@checkout, nonce: 'test-token-another')
    assert_equal 1, @nmi_sales
    Pos::CardPayment.reconcile!(PosPaymentAttempt.first)
    assert @checkout.reload.paid?
    assert_equal 1, @nmi_sales
  end

  test 'malformed response remains recoverable with its durable invoice' do
    @nmi_mode = :malformed
    assert_raises(Pos::Error) { Pos::CardPayment.call(@checkout, nonce: 'test-token-malformed') }
    assert_equal 'unknown', @checkout.reload.status
    assert_nil PosPaymentAttempt.first.transaction_id
    Pos::CardPayment.reconcile!(PosPaymentAttempt.first)
    assert @checkout.reload.paid?
    assert_equal 1, @nmi_sales
  end

  %w[amount currency order].each do |field|
    test "mismatched #{field} is unresolved and never creates a paid receipt" do
      case field
      when 'amount' then @nmi_amount = '1.00'
      when 'currency' then @nmi_currency = 'EUR'
      when 'order' then @nmi_order_override = 'wrong-order'
      end
      assert_raises(Pos::Error) { Pos::CardPayment.call(@checkout, nonce: 'test-token-mismatch') }
      assert_equal 'unknown', @checkout.reload.status
      assert_empty Core::Order.where(source: 'rupert_pos')
      Pos::CardPayment.call(@checkout, nonce: 'test-token-retry')
      assert_equal 1, @nmi_sales
    end
  end

  test 'held transaction remains unknown even when its sale action reports success' do
    @nmi_condition = 'pending'
    assert_raises(Pos::Error) { Pos::CardPayment.call(@checkout, nonce: 'test-token-held') }
    assert_equal 'unknown', @checkout.reload.status
  end

  test 'production is rejected by settings and by the gateway even after bypassing validations' do
    assert_not @setting.update(environment: 'production', card_enabled: true)
    @setting.reload.update_columns(environment: 'production', card_enabled: true, verified_at: Time.current)
    assert_raises(Pos::Error) { Pos::CardPayment.call(@checkout, nonce: 'test-token-production') }
    assert_equal 0, @nmi_sales
    assert_empty PosPaymentAttempt.all
    assert_not_requested :post, Pos::NmiGateway::SALE_URL
    assert_not_requested :post, Pos::NmiGateway::QUERY_URL
  end

  test 'changed company or credential fingerprint fails before sending a payment' do
    @nmi_company = 'Other Company'
    assert_raises(Pos::Error) { Pos::CardPayment.call(@checkout, nonce: 'test-token-company') }
    @nmi_company = 'Sandbox Company'
    @setting.update_columns(credentials_json: { security_key: 'changed-private', tokenization_key: 'sandbox-public-fixture', merchant_company: 'Sandbox Company' }.to_json)
    assert_raises(Pos::Error) { Pos::CardPayment.call(@checkout, nonce: 'test-token-credentials') }
    assert_equal 0, @nmi_sales
  end

  test 'a different tenant cannot use this checkout or its gateway' do
    Current.tenant = Tenant.create!(name: 'Foreign sandbox', subdomain: 'foreign-nmi-sandbox', status: 'active')
    assert_raises(ActiveRecord::RecordNotFound) { Pos::CardPayment.call(@checkout, nonce: 'test-token-foreign') }
    assert_raises(Pos::Error) { Pos::NmiGateway.new(@setting) }
    assert_equal 0, @nmi_sales
  end

  test 'duplicate transactions and external entity reports are rejected' do
    @nmi_xml_override = '<!DOCTYPE nm_response [<!ENTITY x SYSTEM "file:///etc/passwd">]><nm_response>&x;</nm_response>'
    assert_raises(Pos::Error) { Pos::CardPayment.call(@checkout, nonce: 'test-token-entity') }
    assert_equal 'unknown', @checkout.reload.status
    @nmi_xml_override = nmi_transaction_xml.sub('</nm_response>', nmi_transaction_xml[/<transaction>.*<\/transaction>/] + '</nm_response>')
    assert_raises(Pos::Error) { Pos::CardPayment.reconcile!(PosPaymentAttempt.first) }
    assert_equal 1, @nmi_sales
  end

  test 'gateway settings cannot move unresolved payments to another account' do
    @nmi_mode = :timeout
    assert_raises(Pos::Error) { Pos::CardPayment.call(@checkout, nonce: 'test-token-unresolved') }
    assert_not @setting.update(gateway_id: '456')
    assert_not @setting.update(gateway_provider: 'authorize_net', credentials_json: '{}')
    assert_equal '123', @setting.reload.gateway_id
    assert_equal 'nmi', @setting.gateway_provider
  end

  test 'a successful reversal cannot produce a paid sandbox receipt' do
    @nmi_mode = :timeout
    assert_raises(Pos::Error) { Pos::CardPayment.call(@checkout, nonce: 'test-token-reversed') }
    @nmi_xml_override = nmi_transaction_xml.sub('</transaction>', '<action><action_type>refund</action_type><success>1</success><amount>11.66</amount></action></transaction>')
    assert_raises(Pos::Error) { Pos::CardPayment.reconcile!(PosPaymentAttempt.first) }
    assert_equal 'unknown', @checkout.reload.status
    assert_equal 1, @nmi_sales
  end

  test 'overlapping submission during an in-flight sale does not send another charge' do
    @nmi_during_sale = lambda do
      @nmi_during_sale = nil
      result = Pos::CardPayment.call(@checkout.reload, nonce: 'test-token-overlap')
      assert_equal 'processing', result.status
      assert_equal 1, PosPaymentAttempt.count
    end
    Pos::CardPayment.call(@checkout, nonce: 'test-token-first')
    assert @checkout.reload.paid?
    assert_equal 1, @nmi_sales
  end
end
