# frozen_string_literal: true

require 'test_helper'
require 'csv'
require_relative '../support/ctrax_daily_items_fixture'

class CtraxDailyItemsTest < ActiveSupport::TestCase
  include CtraxDailyItemsFixture

  setup do
    Current.tenant = tenants(:default_tenant)
    build_ctrax_items_fixture
  end

  teardown { Current.reset }

  def item(report, variant_id)
    report.items.find { |row| row[:variant_id] == variant_id }
  end

  test 'aggregates completed receipt lines per variant with discounts and refunds kept unknown' do
    report = Ctrax::DailyItems.new([@downtown_day])
    assert_equal %w[102 101 103 104], report.items.map { |row| row[:variant_id] }

    gummies = item(report, '101')
    assert_equal 2, gummies[:quantity], 'pending and deleted receipts are excluded'
    assert_equal 1, gummies[:receipts]
    assert_equal [5000, 300, 0, 0, 0, 5000], gummies.values_at(:gross, :tax, :discount, :refunded_quantity, :refunded_amount, :net)
    assert_equal ['HH-GUM-10', 'Edibles'], gummies.values_at(:sku, :category)

    flower = item(report, '102')
    assert_equal [2, 2, 8000, 450], flower.values_at(:quantity, :receipts, :gross, :tax)
    assert_nil flower[:discount], 'an order discount is never allocated to lines'
    assert_nil flower[:net]
    assert_equal 1, flower[:discounted_receipts]
    assert_equal 0, flower[:refunded_quantity]

    wick = item(report, '104')
    assert_equal 1, wick[:refund_receipts]
    assert_nil wick[:refunded_quantity]
    assert_nil wick[:refunded_amount]
    assert_nil wick[:net]
    assert_nil wick[:sku], 'a variant absent from the stock read has no invented SKU'
    assert_nil wick[:category]

    categories = report.categories.to_h { |row| [row[:category], row.values_at(:quantity, :gross)] }
    assert_equal({ 'Flower' => [2, 8000], 'Edibles' => [2, 5000], 'Pre-rolls' => [1, 1500], nil => [1, 800] }, categories)
  end

  test 'tie-out reconciles item lines to order subtotals, tax and totals' do
    tie = Ctrax::DailyItems.new([@downtown_day]).tie_outs.first
    assert tie[:matched]
    assert_equal [[15_300, 15_300, 0], [858, 858, 0], [15_658, 15_658, 0]], tie[:rows].map { |row| row.values_at(:items, :orders, :delta) }
    assert_equal [3, 6, 2], tie.values_at(:receipts, :units, :excluded)
    assert_equal 500, tie[:components].to_h['Order discounts (not allocated to items)']
    assert_equal({ 'Tips (not in order totals)' => 100, 'Card surcharges (not in order totals)' => 158, 'Source report refunds (not itemized)' => 848 },
      tie[:outside].to_h)

    orders = @downtown_day.orders.map { |order| order['id'] == '501' ? order.merge('total' => 9541) : order }
    @downtown_day.update!(orders_json: orders)
    tie = Ctrax::DailyItems.new([@downtown_day.reload]).tie_outs.first
    assert_not tie[:matched]
    assert_equal(-1, tie[:rows].last[:delta])
  end

  test 'unknown source fields stay unknown instead of becoming zero' do
    orders = @downtown_day.orders.map do |order|
      next order unless order['id'] == '501'

      order.merge('discount' => nil, 'refund_count' => nil, 'lines' => order['lines'].map { |line| line.except('tax') })
    end
    @downtown_day.update!(orders_json: orders)
    report = Ctrax::DailyItems.new([@downtown_day.reload])
    gummies = item(report, '101')
    assert_equal 5000, gummies[:gross]
    assert_nil gummies[:tax]
    assert_nil gummies[:discount]
    assert_nil gummies[:refunded_quantity]
    assert_nil gummies[:discounted_receipts]
    tie = report.tie_outs.first
    assert_equal 15_300, tie[:rows].first[:items]
    assert_nil tie[:rows].second[:items]
    assert_nil tie[:rows].second[:delta]
    assert_nil tie[:rows].last[:items]
    assert_not tie[:matched]
    row = CSV.parse(report.csv, headers: true).find { |r| r['C-Trax variant ID'] == '101' }
    assert_nil row['Line tax (minor units)']
    assert_nil row['Net (minor units)']
  end

  test 'flags sold items without exact Rupert catalog evidence' do
    report = Ctrax::DailyItems.new([@downtown_day])
    assert_equal :catalog, item(report, '101')[:status]
    assert_equal 'SKU candidate', item(report, '101')[:identity]
    assert_equal 'gid://shopify/ProductVariant/9101', item(report, '101')[:catalog_id]

    missing = report.not_in_catalog.to_h { |row| [row[:variant_id], row[:status]] }
    assert_equal({ '102' => :review, '103' => :missing, '104' => :missing }, missing)
    assert_equal 'Blue Dream Flower · 3.5 g', item(report, '102')[:catalog_label]
    assert_includes item(report, '104')[:issues], 'Not in the current C-Trax stock read; SKU/barcode unknown'
    assert_nil item(report, '103')[:catalog_id]
  end

  test 'combines stores on a date without losing per-store tie-outs' do
    report = Ctrax::DailyItems.new([@downtown_day, @uptown_day])
    gummies = item(report, '101')
    assert_equal %w[Downtown Uptown], gummies[:stores]
    assert_equal [3, 2, 7500], gummies.values_at(:quantity, :receipts, :gross)
    assert_equal :catalog, gummies[:status], 'exact evidence in one store is kept for the combined row'
    assert_equal ['Downtown', 'Uptown', 'All stores'], report.tie_outs.map { |tie| tie[:label] }
    assert_equal 18_308, report.tie_outs.last[:rows].last[:orders]
    assert report.matched?

    uptown = Ctrax::DailyItems.new([@uptown_day])
    assert_equal :review, item(uptown, '101')[:status], 'without a stock read only a name/package candidate is possible'
  end

  test 'CSV labels minor units and guards spreadsheet formulas' do
    orders = @downtown_day.orders.map { |order| order['id'] == '503' ? order.merge('lines' => [order['lines'].first.merge('name' => '=HYPERLINK("x")')]) : order }
    @downtown_day.update!(orders_json: orders)
    rows = CSV.parse(Ctrax::DailyItems.new([@downtown_day.reload]).csv, headers: true)
    assert_includes rows.headers, 'Gross line amount (minor units)'
    assert_equal 4, rows.size
    flower = rows.find { |r| r['C-Trax variant ID'] == '102' }
    assert_equal ['2', '8000', nil, 'Name/package candidate · review'], flower.values_at('Quantity (units)', 'Gross line amount (minor units)', 'Net (minor units)', 'Rupert catalog')
    assert_equal "'=HYPERLINK(\"x\")", rows.find { |r| r['C-Trax variant ID'] == '104' }['Product']
  end
end
