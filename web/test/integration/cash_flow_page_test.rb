# frozen_string_literal: true

require 'test_helper'

class CashFlowPageTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:regular_user)
    Current.tenant = tenants(:default_tenant)
    BankStatementImport.new(bytes: "Date,Description,Amount\n#{Date.current - 2},Shopify payout,1200.00\n#{Date.current - 1},Rent,-300.00\n", account_label: 'Operating').import!(filename: 'oct.csv', actor: nil)
    order = Core::Order.create!(source: 'shopify', source_order_id: 's1', occurred_at: 1.day.ago, gross_cents: 2500, currency: 'USD')
    order.mark_paid!
    Core::Payment.create!(order: order, method: 'card', amount_cents: 2500, paid_at: order.occurred_at, status: 'completed')
    post login_path, params: { email: @user.email, password: 'password' }
  end

  teardown { Current.reset }

  test 'the page shows headline figures, tables, position, events and the data block' do
    get finance_cash_flow_path
    assert_response :success
    assert_select 'h1', 'Cash flow'
    assert_select '[data-kpi=cash_in] .stat-value', text: '$1,200.00'
    assert_select '[data-kpi=cash_out] .stat-value', text: '$300.00'
    assert_select '[data-kpi=net] .stat-value', text: '$900.00'
    assert_select '[data-kpi=sales] .stat-value', text: '$25.00'
    assert_select '#cash-flow-bank-table tfoot', text: /\$1,200\.00/
    assert_select '#cash-flow-channels-table th', text: 'Shopify'
    assert_select '#cash-flow-position', text: /Unavailable/
    assert_select '#cash-flow-events li[data-event-kind=sale]', minimum: 1
    assert_select 'script#cash-flow-data[type="application/json"]'
    payload = JSON.parse(css_select('script#cash-flow-data').first.text)
    assert_equal 120_000, payload['kpis']['cash_in']['cents']
    assert_equal 'day', payload['range']['bucket']
    assert_select 'nav[aria-label="Module"] a[aria-current=page]', text: 'Cash flow'
    assert_select 'a.nav-pill', text: 'Last 90 days'
  end

  test 'the live refresh returns turbo streams for every region and json is available' do
    get finance_cash_flow_path(range: '90d'), headers: { 'Accept' => 'text/vnd.turbo-stream.html' }
    assert_response :success
    assert_equal 'text/vnd.turbo-stream.html; charset=utf-8', response.content_type
    %w[cash-flow-meta cash-flow-kpis cash-flow-data cash-flow-bank-table cash-flow-channels-table cash-flow-spend cash-flow-deposits cash-flow-position cash-flow-events].each do |target|
      assert_select "turbo-stream[action=replace][target=#{target}]", 1
    end
    get finance_cash_flow_path(range: '90d', format: :json)
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal 'week', body['range']['bucket']
    assert_equal 120_000, body['kpis']['cash_in']['cents']
  end

  test 'bad dates redirect with a plain message and the finance permission is required' do
    get finance_cash_flow_path(from: '2026-10-10', to: '2026-10-01')
    assert_redirected_to finance_cash_flow_path
    assert_match(/End date/, flash[:alert])
    get finance_cash_flow_path(from: '2026-10-10', to: '2026-10-01', format: :json)
    assert_response :unprocessable_entity

    @user.update!(role: 'employee')
    get finance_cash_flow_path
    assert_not_equal 200, response.status
  end
end
