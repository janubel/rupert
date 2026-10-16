# frozen_string_literal: true

require 'test_helper'
class PosCardPaymentTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
    @location = Location.create!(source: 'ctrax', externalId: 'card-fixture/1', name: 'Card fixture')
    @user = users(:regular_user)
    @display = PosDisplaySession.create!(user: @user, location: @location)
    @register = Sales::PosSession.create!(location: @location, user: @user, name: 'Front', opened_at: Time.current)
    @setting = PosSetting.create!(location: @location, gateway_id: '123', credentials_json: { api_login_id: 'fixture-login', transaction_key: 'fixture-key' }.to_json)
    @setting.update!(verified_at: Time.current, public_client_key: 'fixture-public')
    @setting.update!(card_enabled: true)
    @checkout = PosCheckout.create!(location: @location, user: @user, pos_display_session: @display, pos_session: @register,
      cart_revision: 1, reference: SecureRandom.hex(16), tender: 'card', lines_json: [{ 'variant_id' => '7', 'title' => 'Tea', 'quantity' => 1, 'unit_price' => '10.05', 'line_total' => '10.05' }], subtotal_cents: 1005, tax_cents: 60, tip_cents: 101, total_cents: 1166, gateway_id: '123', environment: 'sandbox')
    @uri = Pos::Gateway::ENDPOINTS.fetch('sandbox')
    @mode = :approved
    @charge_count = 0
    stub_request(:post, @uri).to_return do |request|
      doc = JSON.parse(request.body)
      method = doc.keys.first
      data = case method
      when 'getMerchantDetailsRequest'
        { gatewayId: '123', currencies: ['USD'], publicClientKey: 'fixture-public', isTestMode: false }
      when 'createTransactionRequest'
        @charge_count += 1
        @invoice = doc.dig(method, 'transactionRequest', 'order', 'invoiceNumber')
        assert_equal '11.66', doc.dig(method, 'transactionRequest', 'amount')
        assert_equal 'COMMON.ACCEPT.INAPP.PAYMENT', doc.dig(method, 'transactionRequest', 'payment', 'opaqueData', 'dataDescriptor')
        raise Net::ReadTimeout if @mode == :timeout
        { transactionResponse: { responseCode: @mode == :declined ? '2' : '1', transId: '900' } }
      when 'getTransactionDetailsRequest'
        { transaction: { transId: '900', transactionType: 'authCaptureTransaction', transactionStatus: 'capturedPendingSettlement', responseCode: '1', authAmount: '11.66', order: { invoiceNumber: @invoice } } }
      when 'getUnsettledTransactionListRequest'
        { totalNumInResultSet: 1, transactions: [{ transId: '900', invoiceNumber: @invoice }] }
      when 'getSettledBatchListRequest'
        { batchList: [] }
      else flunk "Unexpected gateway method #{method}"
      end
      { status: 200, headers: { 'Content-Type' => 'application/json' }, body: data.merge(messages: { resultCode: 'Ok' }).to_json }
    end
  end
  teardown { Current.reset }

  test 'only gateway verified approval creates one paid order including confirmed tip' do
    Pos::CardPayment.call(@checkout, nonce: 'fixture-nonce')
    assert @checkout.reload.paid?
    assert_equal 1166, @checkout.order.payments.first.amount_cents
    assert_equal 101, @checkout.order.tip_cents
    assert_equal '900', @checkout.order.payments.first.reference
    Pos::CardPayment.call(@checkout, nonce: 'fixture-nonce')
    assert_equal 1, @charge_count
    assert_equal 1, Core::Order.where(source: 'rupert_pos').count
    assert_equal 1, PosPaymentAttempt.count
    assert_not_includes PosPaymentAttempt.first.attributes.to_json, 'fixture-nonce'
  end

  test 'decline creates no sale and permits a new one-use token' do
    @mode = :declined
    Pos::CardPayment.call(@checkout, nonce: 'declined-token')
    assert_equal 'declined', @checkout.reload.status
    assert_empty Core::Order.where(source: 'rupert_pos')
    @mode = :approved
    Pos::CardPayment.call(@checkout, nonce: 'new-approved-token')
    assert @checkout.reload.paid?
    assert_equal 2, @charge_count
    assert_equal 2, PosPaymentAttempt.count
  end

  test 'lost response remains unknown and reconciliation never sends a second charge' do
    @mode = :timeout
    assert_raises(Pos::Error) { Pos::CardPayment.call(@checkout, nonce: 'lost-response-token') }
    assert_equal 'unknown', @checkout.reload.status
    assert_empty Core::Order.where(source: 'rupert_pos')
    Pos::CardPayment.call(@checkout, nonce: 'lost-response-token')
    assert_equal 1, @charge_count
    Pos::CardPayment.reconcile!(PosPaymentAttempt.first)
    assert @checkout.reload.paid?
    assert_equal 1, @charge_count
    assert_equal 1, Core::Order.where(source: 'rupert_pos').count
  end

  test 'mismatched invoice cannot become paid' do
    gateway = mock
    Pos::Gateway.stubs(:new).returns(gateway)
    gateway.stubs(:merchant).returns({})
    gateway.stubs(:charge).returns('transactionResponse' => { 'responseCode' => '1', 'transId' => '900' })
    gateway.stubs(:detail).returns('transId' => '900', 'transactionStatus' => 'capturedPendingSettlement', 'responseCode' => '1', 'authAmount' => '11.66', 'order' => { 'invoiceNumber' => 'wrong' })
    gateway.stubs(:version).returns(@setting.lock_version)
    assert_raises(Pos::Error) { Pos::CardPayment.call(@checkout, nonce: 'mismatch-token') }
    assert_equal 'unknown', @checkout.reload.status
    assert_empty Core::Order.where(source: 'rupert_pos')
  end
  test 'held payment never creates a paid receipt or a second charge' do
    stub_request(:post, @uri).with { |r| JSON.parse(r.body).key?('getTransactionDetailsRequest') }
      .to_return { { status: 200, body: { messages: { resultCode: 'Ok' }, transaction: { transId: '900', transactionType: 'authCaptureTransaction', transactionStatus: 'FDSAuthorizedPendingReview', responseCode: '4', authAmount: '11.66', order: { invoiceNumber: @invoice } } }.to_json } }
    Pos::CardPayment.call(@checkout, nonce: 'held-token')
    assert_equal 'unknown', @checkout.reload.status
    Pos::CardPayment.call(@checkout, nonce: 'different-token')
    assert_equal 1, @charge_count
    assert_empty Core::Order.where(source: 'rupert_pos')
  end

  test 'foreign merchant account is rejected before a charge is sent' do
    stub_request(:post, @uri).with { |r| JSON.parse(r.body).key?('getMerchantDetailsRequest') }
      .to_return(status: 200, body: { messages: { resultCode: 'Ok' }, gatewayId: '999', currencies: ['USD'], publicClientKey: 'fixture-public', isTestMode: false }.to_json)
    assert_raises(Pos::Error) { Pos::CardPayment.call(@checkout, nonce: 'foreign-account-token') }
    assert_equal 0, @charge_count
    assert_empty PosPaymentAttempt.all
    assert_empty Core::Order.where(source: 'rupert_pos')
  end
end
