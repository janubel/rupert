# frozen_string_literal: true

require 'test_helper'

class BusinessReviewToolsTest < ActiveSupport::TestCase
  setup do
    @tenant = tenants(:default_tenant)
    @user = users(:regular_user)
    Current.tenant = @tenant
    Current.user = @user
    @token = TeamChat::Token.new(@user)
  end

  teardown { Current.reset }

  def order(at:, cents:, channel: 'online', paid: true, number: SecureRandom.hex(3))
    row = Core::Order.create!(source: 'shopify', source_order_id: "t-#{number}", order_number: "##{number}", occurred_at: at,
      gross_cents: cents, tax_cents: 0, currency: 'USD', channel: channel)
    row.mark_paid! if paid
    row.order_lines.create!(name: 'Tea 50g', sku: 'TEA', unit_cents: cents, quantity: 1, line_cents: cents)
    row
  end

  def low_stock_variant(sku:, quantity:)
    product = ShopifyProduct.create!(id: "product-#{sku}", title: "#{sku} tea")
    variant = ShopifyVariant.create!(id: "variant-#{sku}", product: product, title: sku, sku: sku, tracked: true)
    location = Location.create!(source: 'shopify', externalId: "location-#{sku}", name: 'Online')
    InventoryLevel.create!(source: 'shopify', locationId: location.externalId, shopifyVariantId: variant.id,
      quantity: quantity, available: quantity)
    alert = StockAlert.create!(shopifyVariantId: variant.id, sku: sku, quantity: quantity, threshold: 5, status: 'open', note: 'Low stock')
    [variant, alert]
  end

  def call(tool, args = {}) = Mcp::Registry.find(tool).new(token: @token).call(args)

  test 'period_review compares a period with the one before it' do
    order(at: 1.day.ago.change(hour: 12), cents: 6000)
    order(at: 1.day.ago.change(hour: 13), cents: 4000)
    order(at: 2.days.ago.change(hour: 12), cents: 5000)
    Projects::Task.create!(title: 'Done yesterday', priority: 'low').tap { |task| task.update_columns(created_at: 1.day.ago) }

    outcome = call('period_review', { 'period' => 'yesterday' })
    data = outcome.data
    assert_equal (Date.current - 1).iso8601, data[:from]
    assert_equal (Date.current - 2).iso8601, data[:compared_with][:from]
    assert_equal [{ currency: 'USD', orders: 2, gross_cents: 10_000, by_source: { 'shopify' => 10_000 } }], data[:sales]
    assert_equal 100.0, data[:change].first[:gross_change_percent]
    assert_equal 1, data[:activity][:tasks_created]
    assert_equal 'Tea 50g', data[:top_products].first[:name]
    assert_equal data[:sales], data[:money_summary][:gross_sales_by_currency]
    assert data[:money_summary][:expenses_visible]
    assert_match(/do not compare.*profit/i, data[:money_summary][:note])
    assert_match(/Yesterday .*2 orders, 100.00 USD \(\+100.0% USD vs the period before\)/, outcome.text)

    month = call('period_review', { 'period' => 'last_month' }).data
    assert_equal Date.current.prev_month.beginning_of_month.prev_month.iso8601, month[:compared_with][:from]
    assert_raises(Mcp::ToolError) { call('period_review', { 'from' => '2026-10-10', 'to' => '2026-10-01' }) }
  end

  test 'order_queues lists unshipped paid orders, the oldest first, and what is late' do
    late = order(at: 3.days.ago, cents: 2500, number: 'late')
    order(at: 2.hours.ago, cents: 1500, number: 'fresh')
    order(at: 2.days.ago, cents: 900, channel: 'pos', number: 'counter')
    order(at: 2.days.ago, cents: 700, paid: false, number: 'unpaid')

    outcome = call('order_queues')
    unshipped = outcome.data[:queues].find { |queue| queue[:name] == 'Paid online orders not shipped' }
    assert_equal [2, 1], [unshipped[:count], unshipped[:late]]
    assert_equal '#late', unshipped[:oldest_orders].first[:order]
    assert_equal "/orders/#{late.id}", unshipped[:oldest_orders].first[:path]
    StockAlert.create!(sku: 'TEA', quantity: 2, threshold: 5, status: 'open', note: 'Low stock')
    outcome = call('order_queues')
    unshipped = outcome.data[:queues].find { |queue| queue[:name] == 'Paid online orders not shipped' }
    assert_equal 2, outcome.data[:waiting_on_low_stock]
    assert_equal true, unshipped[:oldest_orders].first[:lines].first[:low_stock]
    assert_equal 1, outcome.data[:queues].find { |queue| queue[:name].start_with?('Orders placed') }[:count]
    assert_match(/Paid online orders not shipped: 2 \(1 late\)/, outcome.text)
  end

  test 'compliance_check lists what to fix or watch with the page for each, and says sales tax filings are unknown' do
    outcome = call('compliance_check', { 'include_ok' => true })
    items = outcome.data[:items]
    assert items.any?
    assert(items.all? { |item| %w[ok watch fix unknown].include?(item[:status]) })
    assert(items.select { |item| item[:status] != 'ok' }.all? { |item| item[:path].present? || item[:status] == 'unknown' })
    assert_includes items.map { |item| item[:area] }, 'Books'
    assert_empty items.select { |item| item[:title].end_with?('could not be checked') }, 'every area loads, including the close checklists'
    assert(items.any? { |item| item[:area].end_with?(' close') && item[:path].present? }, 'close checklist items link to their page')
    tax = items.find { |item| item[:area] == 'Sales tax' }
    assert_equal ['unknown', '/reports/sales_tax'], [tax[:status], tax[:path]]
    assert_equal 'sales', tax[:topics].first
    assert_match(/\d+ to fix, \d+ to watch, \d+ ok\./, outcome.text)
    assert_operator call('compliance_check').data[:items].size, :<=, items.size
  end

  test 'sales and inventory rows include separate low-stock observations and alert IDs' do
    _variant, alert = low_stock_variant(sku: 'TEA', quantity: 2)
    order(at: 1.day.ago, cents: 1200)

    sales = call('sales_summary', { 'from' => (Date.current - 2).iso8601, 'to' => Date.current.iso8601 })
    stock = sales.data[:top_products].first[:stock]
    assert_equal true, stock[:low]
    assert_equal 2, stock[:observations].first[:on_hand]
    assert_equal alert.id, stock[:observations].first[:alert_id]

    inventory = call('inventory_search', { 'query' => 'TEA' })
    row = inventory.data[:rows].first
    assert_equal [true, alert.id], [row[:low], row[:alert_id]]
  end

  test 'sales and inventory enrichment respects inventory and alert permissions' do
    low_stock_variant(sku: 'TEA', quantity: 2)
    order(at: 1.day.ago, cents: 1200)

    sales = @user.stub(:can?, ->(permission) { permission != 'inventory.read' }) do
      call('sales_summary', { 'from' => (Date.current - 2).iso8601, 'to' => Date.current.iso8601 })
    end
    stock = sales.data[:top_products].first[:stock]
    refute stock[:available]
    assert_empty stock[:observations]

    inventory = @user.stub(:can?, ->(permission) { permission != 'alerts.read' }) do
      call('inventory_search', { 'query' => 'TEA' })
    end
    row = inventory.data[:rows].first
    assert_equal [true, false, nil], [row[:low], row[:alerts_available], row[:alert_id]]

    queues = @user.stub(:can?, ->(permission) { permission != 'alerts.read' }) { call('order_queues') }
    refute queues.data[:low_stock_available]
    assert_nil queues.data[:waiting_on_low_stock]
  end

  test 'time keeping reports sales for the exact same dates when the user can read sales' do
    order(at: 1.day.ago, cents: 2300)
    from = (Date.current - 2).iso8601
    to = Date.current.iso8601

    outcome = call('time_keeping_report', { 'from' => from, 'to' => to })

    assert_equal [from, to, true], [outcome.data[:sales_same_days][:from], outcome.data[:sales_same_days][:to], outcome.data[:sales_same_days][:available]]
    assert_equal 2300, outcome.data[:sales_same_days][:gross_sales_by_currency].first[:gross_cents]
  end

  test 'overdue stock tasks can link a product by explicit SKU and show its separate stock state' do
    low_stock_variant(sku: 'TEA', quantity: 2)
    task = Projects::Task.create!(title: 'Recount tea shelf', due_on: Date.yesterday, labels: %w[stock sku:TEA])

    outcome = call('list_tasks', { 'topic' => 'stock', 'overdue' => true })
    row = outcome.data[:rows].find { |candidate| candidate[:id] == task.id }

    assert_equal 'TEA', row[:product][:sku]
    assert_equal true, row[:product][:low]
    assert_equal '/projects/tasks', outcome.data[:path]
  end

  test 'sync health identifies which figures a source feeds and states the completeness limit' do
    SyncAttempt.create!(source: 'shopify', operation: 'catalog', status: 'succeeded', queued_at: 10.minutes.ago,
      started_at: 9.minutes.ago, finished_at: 8.minutes.ago)

    outcome = call('sync_health')
    shopify = outcome.data[:channels].find { |row| row[:source] == 'shopify' && row[:operation] == 'catalog' }

    assert_equal %w[sales orders inventory], shopify[:feeds]
    assert_equal [nil, false], [shopify[:complete_through], shopify[:complete_through_known]]
    assert outcome.data[:yesterday_sync_healthy]
    refute outcome.data[:yesterday_complete]
    assert_match(/cannot prove every sale/i, outcome.data[:completeness_note])
  end

  test 'sales by source carries the source sync status when the user may read system health' do
    order(at: Time.current, cents: 4300)
    finished_at = 5.minutes.ago
    SyncAttempt.create!(source: 'shopify', operation: 'catalog', status: 'succeeded', queued_at: 7.minutes.ago,
      started_at: 6.minutes.ago, finished_at: finished_at)

    outcome = call('metric', { 'name' => 'sales_by_source', 'period' => 'today', 'compare' => 'none' })
    shopify = outcome.data[:values].first[:sources].find { |row| row[:source] == 'shopify' }

    assert_equal 'succeeded', shopify[:sync][:status]
    assert_equal finished_at.iso8601, shopify[:sync][:last_ok_at]
  end

  test 'business_pulse returns joined daily sections with their page paths' do
    order(at: Time.current, cents: 3600)
    StockAlert.create!(sku: 'TEA', quantity: 2, threshold: 5, status: 'open', note: 'Low stock')
    Projects::Task.create!(title: 'Recount tea shelf', due_on: Date.yesterday, labels: %w[stock sku:TEA])
    SyncAttempt.create!(source: 'shopify', operation: 'catalog', status: 'failed', queued_at: 1.hour.ago,
      started_at: 1.hour.ago, finished_at: 50.minutes.ago, error_category: 'unknown')

    outcome = call('business_pulse')

    assert_equal 3600, outcome.data[:sales][:gross_sales_by_currency].first[:gross_cents]
    assert_equal '/reports/sales', outcome.data[:sales][:path]
    assert_equal 1, outcome.data[:waiting][:waiting_on_low_stock]
    assert_equal 1, outcome.data[:alerts][:count]
    assert_equal 'shopify', outcome.data[:sync][:rows].first[:source]
    assert_equal 1, outcome.data[:overdue_tasks][:count]
    assert_equal '/projects/tasks', outcome.data[:overdue_tasks][:path]
  end
end
