# frozen_string_literal: true

require 'test_helper'

class MetricsTest < ActiveSupport::TestCase
  TODAY = Date.new(2026, 10, 22) # a Thursday

  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
  end

  teardown { Current.reset }

  def order(day, cents, source: 'shopify', currency: 'USD', name: 'Tea 50g', paid: true)
    row = Core::Order.create!(source: source, source_order_id: SecureRandom.hex(4), occurred_at: day.in_time_zone.change(hour: 12),
      gross_cents: cents, tax_cents: 0, currency: currency)
    row.mark_paid! if paid
    row.order_lines.create!(name: name, sku: name.parameterize, unit_cents: cents, quantity: 1, line_cents: cents)
    row
  end

  def expense(day, cents, category: 'supplies')
    Finance::Expense.create!(payee: 'Metrics fixture', category: category, amount_cents: cents, incurred_on: day)
  end

  def metric(name, **options) = Metrics.call(name, today: TODAY, **options)

  test 'gross sales per currency, with each source, compared with the period before' do
    order(TODAY - 1, 10_000)
    order(TODAY - 1, 5_000, source: 'square')
    order(TODAY - 2, 6_000)
    order(TODAY - 1, 9_999, currency: 'CAD')
    order(TODAY - 1, 77_777, paid: false)

    result = metric('gross_sales', period: 'yesterday')
    usd = result[:values].find { |row| row[:currency] == 'USD' }
    assert_equal [15_000, '$150.00', 2], [usd[:value], usd[:formatted], usd[:orders]]
    assert_equal [['shopify', 66.7], ['square', 33.3]], usd[:sources].map { |row| [row[:source], row[:share_percent]] }
    change = result[:change].find { |row| row[:currency] == 'USD' }
    assert_equal ['up', 9_000, 150.0, 'up $90.00 (+150.0%)'], change.values_at(:direction, :change_amount, :change_percent, :formatted)
    assert_equal %w[CAD USD], result[:values].pluck(:currency), 'currencies are never added together'
    assert_equal({ label: 'Yesterday', from: '2026-10-21', to: '2026-10-21' }, result[:period])
    assert_equal '2026-10-20', result[:compared_with][:from]
    assert_match(/\AGross sales, Yesterday \(2026-10-21 to 2026-10-21\): 99\.99 CAD.*; \$150\.00, up \$90\.00 \(\+150\.0%\) vs the period before/, result[:text])
    assert_includes result[:caveats], 'Currencies are separate; never add them together.'
  end

  test 'orders, average order value, best day, sources, top products and refund rate' do
    order(TODAY - 10, 2_000, name: 'Mints')
    order(TODAY - 10, 4_000, name: 'Tea 50g')
    order(TODAY - 3, 10_000, name: 'Tea 50g', source: 'rupert_pos')
    refunded = order(TODAY - 3, 1_000, name: 'Mints')
    Core::Refund.create!(order: refunded, amount_cents: 1_000, refunded_at: (TODAY - 2).in_time_zone.change(hour: 9), method: 'card')

    window = { from: (TODAY - 29).iso8601, to: TODAY.iso8601 }
    assert_equal 4, metric('orders', **window)[:values].first[:value]
    assert_equal ['$42.50'], metric('average_order_value', **window)[:values].pluck(:formatted)
    best = metric('best_day', **window)[:values].first
    assert_equal ['2026-10-19', 11_000, 2], best.values_at(:value, :gross_cents, :orders)
    sources = metric('sales_by_source', **window)[:values].first[:sources]
    assert_equal [['rupert_pos', 58.8], ['shopify', 41.2]], sources.map { |row| [row[:source], row[:share_percent]] }
    top = metric('top_products', **window)[:values].first[:products]
    assert_equal [['Tea 50g', '$140.00', 82.4], ['Mints', '$30.00', 17.6]], top.map { |row| row.values_at(:name, :revenue, :share_percent) }
    refunds = metric('refund_rate', **window)[:values].first
    assert_equal [5.88, '5.88%', 1, '$10.00'], refunds.values_at(:value, :formatted, :refunds, :refunded)
    assert_equal [{ currency: 'USD', value: 10_000, formatted: '$100.00', orders: 1, gross_cents: 10_000,
                    sources: [{ source: 'rupert_pos', orders: 1, gross_cents: 10_000, gross: '$100.00', share_percent: 100.0 }] }],
      metric('gross_sales', **window, source: 'rupert_pos', compare: 'none')[:values]
  end

  test 'same dates last year, an empty period, and bad requests' do
    order(TODAY - 1, 8_000)
    order((TODAY - 1).prev_year, 10_000)
    change = metric('gross_sales', period: 'yesterday', compare: 'last_year')[:change].first
    assert_equal ['down', -2_000, -20.0], change.values_at(:direction, :change_amount, :change_percent)

    empty = metric('orders', period: 'last_quarter', compare: 'none')
    assert_empty empty[:values]
    assert_match(/does not prove zero sales/, empty[:caveats].join)
    assert_nil empty[:change]

    assert_raises(ArgumentError) { metric('profit_margin') }
    assert_raises(ArgumentError) { metric('orders', period: 'last_decade') }
    assert_raises(ArgumentError) { metric('orders', compare: 'tomorrow') }
    assert_raises(ArgumentError) { metric('orders', from: '2026-10-10', to: '2026-10-01') }
  end

  test 'expenses by category uses active register entries and compares totals' do
    expense(TODAY - 1, 10_000, category: 'supplies')
    expense(TODAY - 1, 2_500, category: 'software')
    expense(TODAY - 2, 1_000, category: 'supplies')
    expense(TODAY, 90_000, category: 'software') # outside the requested period
    removed = expense(TODAY - 1, 80_000, category: 'rent')
    removed.discard!

    result = metric('expenses_by_category', period: 'yesterday')
    assert_equal [{ currency: 'USD', value: 12_500, formatted: '$125.00', expense_count: 2,
                    categories: [
                      { key: 'supplies', name: 'Supplies', amount_cents: 10_000, formatted: '$100.00', expenses: 1, share_percent: 80.0 },
                      { key: 'software', name: 'Software', amount_cents: 2_500, formatted: '$25.00', expenses: 1, share_percent: 20.0 }
                    ] }], result[:values]
    assert_equal ['USD', 11_500, 1_150.0, 'up $115.00 (+1150.0%)'], result[:change].first.values_at(:currency, :change_amount, :change_percent, :formatted)
    assert_match(/\$125\.00 by category: Supplies \$100\.00, Software \$25\.00/, result[:text])
    assert_includes result[:caveats].first, 'removed expenses and vendor payments are excluded'

    assert_raises(ArgumentError) { metric('expenses_by_category', period: 'yesterday', source: 'shopify') }
  end

  test 'expenses by category explains an empty period' do
    result = metric('expenses_by_category', period: 'last_quarter', compare: 'none')

    assert_empty result[:values]
    assert_match(/no active expense records/, result[:text])
    assert_match(/does not prove there was no money out/, result[:caveats].join)
    assert_nil result[:change]
  end
end
