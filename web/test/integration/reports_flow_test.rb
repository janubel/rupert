# frozen_string_literal: true

require 'test_helper'

class ReportsFlowTest < ActionDispatch::IntegrationTest
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
    Current.tenant = tenants(:default_tenant)
    @tenant = tenants(:default_tenant)
    EnvStore.set('SHOPIFY_CLIENT_ID', 'test-client-id')
    EnvStore.set('SHOPIFY_CLIENT_SECRET', 'test-client-secret')
    post login_path, params: { email: 'admin@example.com', password: 'password' }

    @loc = Location.create!(source: 'square', externalId: 'loc1', name: 'Main Shop', tenant_id: @tenant.id)
    order = Core::Order.new(
      source: 'square',
      source_order_id: 'sq-1',
      channel: 'pos',
      gross_cents: 2500,
      tax_cents: 200,
      occurred_at: Time.current,
      tenant_id: @tenant.id,
      location_id: @loc.externalId
    )
    order.mark_paid!
    order.save!
    order.order_lines.create!(tenant_id: @tenant.id, sku: 'OIL-1', name: 'CBD Oil', quantity: 1, line_cents: 2500)
    order.payments.create!(tenant_id: @tenant.id, method: 'card', amount_cents: 2500, status: 'completed',
      paid_at: Time.current)

    ShopifyVariant.create!(
      title: 'Oil',
      sku: 'OIL-1',
      productId: 'p1',
      price: 25.0,
      inventoryQuantity: 3,
      tenant_id: @tenant.id
    )
    ShopifyProduct.create!(id: 'p1', title: 'CBD', tenant_id: @tenant.id)
  end

  teardown do
    Current.tenant = nil
    EnvStore.set('SHOPIFY_CLIENT_ID', nil)
    EnvStore.set('SHOPIFY_CLIENT_SECRET', nil)
  end

  test 'sales report renders charts and top products' do
    get sales_reports_path
    assert_response :success
    assert_select 'h1', /Sales report/
    assert_select 'td', /CBD Oil/
  end

  test 'financial report renders P&L and tenders' do
    get financial_reports_path
    assert_response :success
    assert_select 'h1', /Financial report/
    assert_select 'td', /Net revenue/
    assert_select 'td', /Gross revenue/
    assert_select 'td', /Tax collected/
  end

  test 'inventory report renders valuation and low stock' do
    get inventory_reports_path
    assert_response :success
    assert_select 'h1', /Inventory report/
    assert_select 'td', /OIL-1/
  end

  test 'operations report renders' do
    get operations_reports_path
    assert_response :success
    assert_select 'h1', /Operations report/
  end

  test 'reconciliation report renders side-by-side Shopify vs Square' do
    SquareItem.create!(id: 'sqitem1', name: 'CBD', tenant_id: @tenant.id)
    SquareVariation.create!(id: 'sqvar1', itemId: 'sqitem1', name: 'Oil', sku: 'OIL-1', tenant_id: @tenant.id)
    SkuLink.create!(sku: 'OIL-1', shopifyVariantId: ShopifyVariant.last.id, squareVariationId: 'sqvar1',
      tenant_id: @tenant.id)
    InventoryLevel.create!(source: 'square', locationId: @loc.externalId, squareVariationId: 'sqvar1', quantity: 5,
      tenant_id: @tenant.id)

    get reconciliation_reports_path
    assert_response :success
    assert_select 'h1', /Inventory reconciliation/
    assert_select 'td', /OIL-1/
    assert_select 'td', /CBD/
    assert_select 'td', /linked/
  end

  test 'reconciliation report exports CSV' do
    get reconciliation_reports_path(format: :csv)
    assert_response :success
    assert_equal 'text/csv', response.media_type
    assert_includes response.body, 'SKU'
    assert_includes response.body, 'Square qty'
    assert_includes response.body, 'OIL-1'
  end

  test 'reports export CSV' do
    get sales_reports_path(format: :csv)
    assert_response :success
    assert_equal 'text/csv', response.media_type
    assert_includes response.body, 'Day'
    assert_includes response.body, 'Revenue'
  end

  test 'readers can view reports' do
    User.create!(
      email: 'reporter@example.com',
      password: 'password123',
      role: 'reader',
      tenant: tenants(:default_tenant)
    )
    delete logout_path
    post login_path, params: { email: 'reporter@example.com', password: 'password123' }

    get sales_reports_path
    assert_response :success
  end

  test 'sales tax is a report tab with custom dates, source filter and CSV' do
    get sales_tax_reports_path(from: 1.day.ago.to_date.iso8601, to: Date.current.iso8601)
    assert_response :success
    assert_select 'h1', 'Sales tax'
    assert_select 'nav[aria-label=Reports] a[aria-current=page]', 'Sales tax'
    assert_select 'td', /Main Shop/
    assert_select '[data-controller=report-table] table'
    assert_select 'input[type=checkbox][name="sources[]"][value=ctrax]'

    get sales_tax_reports_path(sources: ['shopify'])
    assert_response :success
    assert_select 'td', { text: /Main Shop/, count: 0 }

    get sales_tax_reports_path(from: Date.current.iso8601, to: 2.days.ago.to_date.iso8601)
    assert_response :success, 'set_range swaps a backwards range'

    get sales_tax_reports_path(rate: '99')
    assert_redirected_to sales_tax_reports_path

    get sales_tax_reports_path(format: :csv, rate: '6.35')
    assert_response :success
    assert_includes response.body, 'Sales tax report'
    assert_includes response.body, '6.35%'
  end

  test 'every report tab shows the tab bar, date presets and a customizable table' do
    [sales_reports_path, financial_reports_path, inventory_reports_path, operations_reports_path, reconciliation_reports_path].each do |path|
      get path
      assert_response :success
      assert_select 'nav[aria-label=Reports] a', /Sales tax/
      assert_select 'nav[aria-label="Quick date ranges"] a', /Last quarter/
      assert_select '[data-controller=report-table] table', minimum: 1
    end
    get register_summary_reports_path
    assert_response :success
    assert_select 'nav[aria-label=Reports] a[aria-current=page]', 'Register summary'
    assert_select '[data-controller=report-table] table', 4
  end

  test 'report tabs keep custom dates while switching' do
    get sales_reports_path(from: '2026-07-01', to: '2026-09-30')
    assert_response :success
    assert_select "nav[aria-label=Reports] a[href*='from=2026-07-01'][href*='to=2026-09-30']", minimum: 5
  end

  test 'every report has previous and next period links that keep the window length' do
    get sales_tax_reports_path(from: '2026-09-01', to: '2026-09-30')
    assert_select 'nav[aria-label="Report period"] strong', 'September 2026'
    assert_select "nav[aria-label='Report period'] a[rel=prev][href*='from=2026-08-01'][href*='to=2026-08-31']"
    assert_select "nav[aria-label='Report period'] a[rel=next][href*='from=2026-10-01'][href*='to=2026-10-31']"
    get sales_reports_path(from: '2026-07-01', to: '2026-09-30')
    assert_select "nav[aria-label='Report period'] a[rel=prev][href*='from=2026-04-01'][href*='to=2026-06-30']"
    get register_summary_reports_path(day: '2026-10-08')
    assert_select "nav[aria-label='Report period'] a[rel=prev][href*='day=2026-10-07']", /Previous day/
    assert_select "nav[aria-label='Report period'] a[rel=next][href*='day=2026-10-09']", /Next day/
  end
end
