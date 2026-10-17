# frozen_string_literal: true

require 'test_helper'

class SoftDeleteTest < ActionDispatch::IntegrationTest
  module TestShopifySession
    def current_shopify_session
      @test_session ||= ShopifyAPI::Auth::Session.new(
        shop: 'm11u0i-sb.myshopify.com',
        access_token: 'test-token',
        is_online: false,
        expires: Time.now + 3600
      )
    end
  end

  ShopifyApp::TokenExchange.prepend(TestShopifySession)

  setup do
    ShopifyAPI::Context.setup(
      api_key: 'test-key',
      api_secret_key: 'test-secret',
      api_version: ShopifyAPI::AdminVersions::SUPPORTED_ADMIN_VERSIONS.first,
      host_name: 'localhost',
      scope: 'read_products',
      is_private: false,
      is_embedded: false
    )
    Shop.create!(shopify_domain: 'm11u0i-sb.myshopify.com', shopify_token: 'test-token')

    @tenant = Tenant.create!(name: 'Test Co', subdomain: 'testco')
    @user = User.create!(email: 'soft@example.com', password: 'password123', role: 'admin', tenant_id: @tenant.id)
    post login_path, params: { email: 'soft@example.com', password: 'password123' }
    Current.tenant = @tenant
  end

  teardown do
    Current.tenant = nil
  end

  def get_page(path)
    get(path, params: { shop: 'm11u0i-sb.myshopify.com', embedded: '1', host: 'test-host' })
  end

  test 'deleting an expense soft-deletes it and it can be restored' do
    expense = Finance::Expense.create!(tenant_id: @tenant.id, payee: 'Soft Co', category: 'supplies',
      amount_cents: 5000, incurred_on: Date.current, method: 'card')

    post finance_expense_path(expense), params: {
      _method: 'delete', shop: 'm11u0i-sb.myshopify.com', embedded: '1'
    }
    follow_redirect!
    assert_response :success

    assert expense.reload.discarded?
    # hidden from the default register
    get_page finance_expenses_path
    assert_select 'td', text: /Soft Co/, count: 0

    # restore
    post restore_finance_expense_path(expense), params: { shop: 'm11u0i-sb.myshopify.com', embedded: '1' }
    follow_redirect!
    assert_response :success
    refute expense.reload.discarded?

    get_page finance_expenses_path
    assert_select 'td', /Soft Co/
  end

  test "deleted payments don't count toward accounts payable" do
    vendor = Purchasing::Vendor.create!(tenant_id: @tenant.id, name: 'Soft Vendor')
    po = Purchasing::PurchaseOrder.create!(tenant_id: @tenant.id, vendor_id: vendor.id, order_number: 'PO-SOFT')
    po.lines.create!(tenant_id: @tenant.id, name: 'Goods', quantity: 1, unit_cost_cents: 10_000) # $100
    po.place_order!
    po.lines.each { |line| line.update!(received_quantity: line.quantity) }
    po.mark_received!

    payment = Finance::VendorPayment.create!(tenant_id: @tenant.id, vendor_id: vendor.id, amount_cents: 4000,
      paid_on: Date.current, method: 'check')
    assert_equal 6000, Purchasing::Payables.total_cents

    payment.discard
    assert_equal 10_000, Purchasing::Payables.total_cents # deleted payment no longer reduces AP
  end
end
