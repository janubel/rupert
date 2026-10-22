# frozen_string_literal: true

require 'test_helper'

class FinanceFlowTest < ActionDispatch::IntegrationTest
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
    @user = User.create!(email: 'finance@example.com', password: 'password123', role: 'admin', tenant_id: @tenant.id)
    post login_path, params: { email: 'finance@example.com', password: 'password123' }
    Current.tenant = @tenant
    Finance::ChartOfAccounts.seed! # expenses post to the ledger, which needs the chart
  end

  teardown do
    Current.tenant = nil
  end

  def get_page(path)
    get(path, params: { shop: 'm11u0i-sb.myshopify.com', embedded: '1', host: 'test-host' })
  end

  test 'record an expense and it shows in the register' do
    get_page finance_expenses_path
    assert_response :success
    assert_select 'h1', /Expenses/

    post finance_expenses_path, params: {
      expense: { payee: 'Utility Co', category: 'utilities', amount: '125.50', incurred_on: '2026-08-01',
                 method: 'bank_transfer' },
      shop: 'm11u0i-sb.myshopify.com',
      embedded: '1'
    }
    follow_redirect!
    assert_response :success

    expense = Finance::Expense.find_by!(payee: 'Utility Co')
    assert_equal 12_550, expense.amount_cents
    assert_equal 'utilities', expense.category
    assert_select 'td', /Utility Co/
  end

  test 'accounts page shows payables and receivables' do
    vendor = Purchasing::Vendor.create!(tenant_id: @tenant.id, name: 'Supply Co')
    po = Purchasing::PurchaseOrder.create!(tenant_id: @tenant.id, vendor_id: vendor.id, order_number: 'PO-F1')
    po.lines.create!(tenant_id: @tenant.id, name: 'Boxes', quantity: 5, unit_cost_cents: 2000) # $100
    po.place_order!
    po.lines.each { |line| line.update!(received_quantity: line.quantity) }
    po.mark_received!

    customer = Core::Customer.create!(tenant_id: @tenant.id, source: 'shopify', external_id: 'fin1', first_name: 'Ada')
    order = Core::Order.new(
      source: 'shopify',
      source_order_id: 'fin1',
      channel: 'online',
      gross_cents: 5000,
      occurred_at: Time.current,
      tenant_id: @tenant.id,
      customer_id: customer.id
    )
    order.mark_paid!
    order.save!
    order.payments.create!(tenant_id: @tenant.id, method: 'card', amount_cents: 3000, status: 'completed',
      paid_at: Time.current)

    get_page finance_accounts_path
    assert_response :success
    assert_select 'h1', 'Accounts'
    assert_select 'th[scope=row]', /Supply Co/
    assert_select 'th[scope=row]', /Ada/
  end

  test 'recording a vendor payment reduces the payable balance' do
    vendor = Purchasing::Vendor.create!(tenant_id: @tenant.id, name: 'Pay Me')
    po = Purchasing::PurchaseOrder.create!(tenant_id: @tenant.id, vendor_id: vendor.id, order_number: 'PO-F2')
    po.lines.create!(tenant_id: @tenant.id, name: 'Goods', quantity: 2, unit_cost_cents: 5000) # $100
    po.place_order!
    po.lines.each { |line| line.update!(received_quantity: line.quantity) }
    po.mark_received!

    assert_equal 10_000, Purchasing::Payables.total_cents

    post finance_vendor_payments_path, params: {
      vendor_payment: { vendor_id: vendor.id, amount: '40.00', paid_on: '2026-08-02', method: 'check' },
      shop: 'm11u0i-sb.myshopify.com',
      embedded: '1'
    }
    follow_redirect!
    assert_response :success

    assert_equal 6000, Purchasing::Payables.total_cents
    assert_select 'td', /Pay Me/
  end

  test 'vendor payments index lists recent payments' do
    vendor = Purchasing::Vendor.create!(tenant_id: @tenant.id, name: 'Payment Co')
    Finance::VendorPayment.create!(tenant_id: @tenant.id, vendor_id: vendor.id, amount_cents: 2500,
      paid_on: Date.current, method: 'ach')

    get_page finance_vendor_payments_path
    assert_response :success
    assert_select 'h1', 'Vendor payments'
    assert_select 'td', /Payment Co/
    assert_select 'td', /25\.00/
  end
end
