# frozen_string_literal: true

require 'test_helper'

class AuthorizeNetSaleLinksTest < ActionDispatch::IntegrationTest
  setup do
    Current.tenant = tenants(:default_tenant)
    @user = users(:regular_user)
    @order = Core::Order.create!(source: 'shopify', source_order_id: 'synthetic-native-order', order_number: '#SYNTHETIC',
      occurred_at: Time.current, gross_cents: 11000, currency: 'USD')
    @payment = AuthorizeNetTransaction.create!(environment: 'production', gateway_id: '12345', source_transaction_id: '9001',
      transaction_type: 'authCaptureTransaction', payment_status: 'capturedPendingSettlement', submitted_at: Time.current,
      currency: 'USD', authorized_amount: '110', settled_amount: '110', observed_at: Time.current, invoice_number: '#SYNTHETIC')
    post login_path, params: { email: @user.email, password: 'password' }
  end
  teardown { Current.reset }

  test 'exact suggestions are proposals and only explicit review creates a match' do
    assert_no_difference -> { AuthorizeNetSaleLink.count } do
      get authorize_net_sale_links_path
    end
    assert_response :success
    assert_equal 'no-store', response.headers['Cache-Control']
    assert_includes response.body, 'Shopify: #SYNTHETIC'
    assert_difference -> { AuthorizeNetSaleLink.count }, 1 do
      post authorize_net_sale_links_path, params: match_params
    end
    assert_response :redirect
    Current.tenant = tenants(:default_tenant)
    link = AuthorizeNetSaleLink.first
    assert_equal @order.id, link.order_id
    post revoke_authorize_net_sale_link_path(link)
    assert_response :redirect
    assert link.reload.revoked_at
  end

  test 'read-only payroll access cannot create or revoke matches' do
    @user.update_permission_overrides!(['payroll.read'])
    get authorize_net_sale_links_path
    assert_response :success
    assert_select 'input[type="submit"]', count: 0
    assert_no_difference -> { AuthorizeNetSaleLink.count } do
      post authorize_net_sale_links_path, params: match_params
    end
    assert_response :redirect
  end

  test 'missing evidence ambiguous references and source mismatches fail without links' do
    assert_no_difference -> { AuthorizeNetSaleLink.count } do
      post authorize_net_sale_links_path, params: match_params.merge(evidence_note: '')
      post authorize_net_sale_links_path, params: match_params.merge(source: 'square')
      Current.tenant = tenants(:default_tenant)
      Core::Order.create!(source: 'shopify', source_order_id: 'duplicate-reference', order_number: '#SYNTHETIC',
        occurred_at: Time.current, gross_cents: 11000, currency: 'USD')
      post authorize_net_sale_links_path, params: match_params
    end
  end

  private

  def match_params
    { payment_id: @payment.id, source: 'shopify', order_reference: '#SYNTHETIC', evidence_note: 'Both source receipts confirm the same sale.' }
  end
end
