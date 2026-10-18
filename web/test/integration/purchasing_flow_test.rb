# frozen_string_literal: true

require 'test_helper'

class PurchasingFlowTest < ActionDispatch::IntegrationTest
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
    @user = User.create!(email: 'buyer@example.com', password: 'password123', role: 'admin', tenant_id: @tenant.id)
    post login_path, params: { email: 'buyer@example.com', password: 'password123' }
    Current.tenant = @tenant
  end

  teardown do
    Current.tenant = nil
  end

  def get_page(path)
    get(path, params: { shop: 'm11u0i-sb.myshopify.com', embedded: '1', host: 'test-host' })
  end

  test 'vendors index and create a vendor' do
    get_page purchasing_vendors_path
    assert_response :success
    assert_select 'h1', /Vendors/

    post purchasing_vendors_path, params: {
      vendor: { name: 'GreenLeaf', email: 'sales@greenleaf.com', payment_terms: 'net30' },
      shop: 'm11u0i-sb.myshopify.com',
      embedded: '1'
    }
    follow_redirect!
    assert_response :success

    vendor = Purchasing::Vendor.find_by!(name: 'GreenLeaf')
    assert_equal 'net30', vendor.payment_terms
    assert_select 'h1', /GreenLeaf/
  end

  test 'full purchase order lifecycle: draft, lines, place, receive' do
    vendor = Purchasing::Vendor.create!(tenant_id: @tenant.id, name: 'Acme Botanicals')

    get_page new_purchasing_purchase_order_path
    assert_response :success

    post purchasing_purchase_orders_path, params: {
      purchase_order: { vendor_id: vendor.id, order_number: 'PO-202608-1', expected_date: '2026-09-01' },
      shop: 'm11u0i-sb.myshopify.com',
      embedded: '1'
    }
    follow_redirect!
    assert_response :success

    po = Purchasing::PurchaseOrder.find_by!(order_number: 'PO-202608-1')
    assert_equal 'draft', po.status

    post add_line_purchasing_purchase_order_path(po), params: {
      name: 'Honey Sticks',
      sku: 'TEA-50',
      quantity: '10',
      unit_cost: '8.50',
      shop: 'm11u0i-sb.myshopify.com',
      embedded: '1'
    }
    follow_redirect!
    assert_response :success

    po.reload
    assert_equal 1, po.lines.count
    assert_equal 850, po.lines.first.unit_cost_cents
    assert_equal 8500, po.total_cents # 10 × $8.50

    post place_order_purchasing_purchase_order_path(po), params: { shop: 'm11u0i-sb.myshopify.com', embedded: '1' }
    follow_redirect!
    assert_response :success
    assert_equal 'ordered', po.reload.status

    # Partial receive (6 of 10)
    line = po.lines.first
    post receive_purchasing_purchase_order_path(po), params: {
      request_token: SecureRandom.uuid,
      received: { line.id.to_s => '6' },
      shop: 'm11u0i-sb.myshopify.com',
      embedded: '1'
    }
    follow_redirect!
    assert_response :success
    assert_equal 6, line.reload.received_quantity
    assert_equal 'ordered', po.reload.status # not fully received yet

    # Full receive
    post receive_purchasing_purchase_order_path(po), params: {
      request_token: SecureRandom.uuid,
      received: { line.id.to_s => '10' },
      shop: 'm11u0i-sb.myshopify.com',
      embedded: '1'
    }
    follow_redirect!
    assert_response :success
    assert_equal 'received', po.reload.status
    assert_equal 8500, po.received_cents
  end

  test "purchase order without lines can't be placed" do
    vendor = Purchasing::Vendor.create!(tenant_id: @tenant.id, name: 'Empty Co')
    po = Purchasing::PurchaseOrder.create!(tenant_id: @tenant.id, vendor_id: vendor.id, order_number: 'PO-1')

    post place_order_purchasing_purchase_order_path(po), params: { shop: 'm11u0i-sb.myshopify.com', embedded: '1' }
    follow_redirect!
    assert_response :success
    assert_equal 'draft', po.reload.status
  end

  test "vendor with orders can't be deleted" do
    vendor = Purchasing::Vendor.create!(tenant_id: @tenant.id, name: 'Locked Co')
    Purchasing::PurchaseOrder.create!(tenant_id: @tenant.id, vendor_id: vendor.id, order_number: 'PO-2')

    delete purchasing_vendor_path(vendor), params: { shop: 'm11u0i-sb.myshopify.com', embedded: '1' }
    follow_redirect!
    assert_response :success
    assert Purchasing::Vendor.exists?(vendor.id)
  end
end
