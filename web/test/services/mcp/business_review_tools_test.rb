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
    tax = items.find { |item| item[:area] == 'Sales tax' }
    assert_equal ['unknown', '/reports/sales_tax'], [tax[:status], tax[:path]]
    assert_match(/\d+ to fix, \d+ to watch, \d+ ok\./, outcome.text)
    assert_operator call('compliance_check').data[:items].size, :<=, items.size
  end
end
