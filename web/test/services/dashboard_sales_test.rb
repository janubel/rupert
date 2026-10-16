# frozen_string_literal: true

require 'test_helper'

class DashboardSalesTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
    Core::Order.delete_all
    @now = Time.zone.parse('2026-10-16 16:00:00')
    @location = Location.create!(source: 'ctrax', externalId: 'fixture/7', name: 'Retail')
  end
  teardown { Current.reset }

  test 'sales cards and charts use orders once and never payment or deposit mirrors' do
    order = canonical(source: 'shopify', source_order_id: 'online', status: 'paid',
      occurred_at: @now - 1.hour, gross_cents: 2000, currency: 'USD')
    order.payments.create!(method: 'card', status: 'completed', amount_cents: 2000, paid_at: @now)
    canonical(source: 'square', source_order_id: 'cancelled', status: 'cancelled',
      occurred_at: @now, gross_cents: 9000, currency: 'USD')
    canonical(source: 'swipesimple', source_order_id: 'payment-mirror', status: 'paid',
      occurred_at: @now, gross_cents: 8000, currency: 'USD')
    snapshot(orders: [native_order('41', 1000), native_order('42', 9000).merge('status' => 'pending'),
      native_order('43', 9000).merge('deleted' => true)])
    result = DashboardSales.new(now: @now)
    assert_equal 3000, result.gross
    assert_equal 2, result.count
    assert_equal 30.0, result.daily.values.sum
    assert_equal 2, result.daily(metric: :count).values.sum
    assert_equal 30.0, result.hourly.values.sum
    assert_equal [['ctrax', 1000, 1], ['shopify', 2000, 1]], result.groups
    assert_equal 10.0, result.daily(source: 'ctrax').values.sum
    travel_to(@now) do
      presenter = DashboardPresenter.new
      assert_equal 3000, presenter.today_revenue
      assert_equal 2, presenter.today_orders
      assert_equal 30.0, presenter.source_breakdown.values.sum
      assert_equal 30.0, presenter.revenue_series.values.sum
    end
  end

  test 'refunded orders keep their original sale amount without subtracting or adding refund payments' do
    order = canonical(source: 'shopify', source_order_id: 'refunded', status: 'refunded',
      occurred_at: @now, gross_cents: 2000, currency: 'USD')
    order.refunds.create!(amount_cents: 2000, method: 'card', refunded_at: @now)
    assert_equal 2000, DashboardSales.new(now: @now).gross
    assert_equal 1, DashboardSales.new(now: @now).count
  end

  test 'native identity spans dates and keeps stores independent' do
    snapshot(orders: [native_order('41', 1000)], captured_at: @now - 2.hours)
    snapshot(date: @now.to_date - 1, orders: [native_order('41', 1000)])
    other = Location.create!(source: 'ctrax', externalId: 'fixture/8', name: 'Second store')
    snapshot(location: other, orders: [native_order('41', 500)])
    result = DashboardSales.new(now: @now)
    # The newest conflicting date is excluded; it cannot inflate the total.
    assert_equal 500, result.gross
    assert_equal 1, result.count
    assert_match(/Repeated C-Trax/, result.warnings.join)
    assert_match(/conflicting dates/, result.warnings.join)
  end

  test 'missing money currency and refund evidence stay explicit' do
    snapshot(orders: [native_order('41', nil), native_order('42', 1200).merge('refund_count' => 1)])
    canonical(source: 'square', source_order_id: 'foreign', status: 'paid',
      occurred_at: @now, gross_cents: 9000, currency: 'CAD')
    result = DashboardSales.new(now: @now)
    assert_equal 1200, result.gross
    assert_match(/non-USD/, result.warnings.join)
    assert_match(/refunds/, result.warnings.join)
  end

  test 'business day and range boundaries use completion time including DST' do
    travel_to(Time.zone.parse('2026-11-01 12:00:00')) do
      snapshot(date: Date.current, orders: [native_order('41', 500).merge('completed_at' => '2026-11-01T01:30:00-04:00'),
        native_order('42', 700).merge('completed_at' => '2026-11-01T01:30:00-05:00'),
        native_order('43', 900).merge('completed_at' => '2026-11-02T00:00:00-05:00')])
      result = DashboardSales.new(now: Time.current)
      assert_equal 1200, result.gross
      assert_equal 12.0, result.hourly[1]
    end
  end

  test 'tenant data and sales permissions remain isolated and snapshots refresh without catalog sync' do
    day = snapshot(orders: [native_order('41', 1000)])
    travel_to(@now) do
      assert_equal 1000, DashboardPresenter.new.today_revenue
      day.update!(orders_json: [native_order('41', 1500)])
      assert_equal 1500, DashboardPresenter.new.today_revenue
      reader = mock
      reader.stubs(:can?).returns(false)
      assert_equal 0, DashboardPresenter.new(user: reader).today_revenue
      assert_empty DashboardPresenter.new(user: reader).sales_freshness
    end
    other = Tenant.create!(name: 'Other shop', subdomain: 'dashboard-other', status: 'active')
    Current.set(tenant: other) { assert_equal 0, DashboardSales.new(now: @now).gross }
  end

  private

  def canonical(**attributes)
    status = attributes.delete(:status)
    order = Core::Order.new(attributes)
    order[:status] = status
    order.save!
    order
  end

  def native_order(id, cents)
    { 'id' => id, 'status' => 'completed', 'deleted' => false, 'total' => cents,
      'tip' => 200, 'completed_at' => (@now - 1.hour).iso8601, 'refund_count' => 0,
      'payments' => [{ 'amount' => cents, 'total_amount' => cents.to_i + 200 }] }
  end

  def snapshot(orders:, date: @now.to_date, location: @location, captured_at: @now)
    CtraxDay.create!(location: location, business_date: date, api_origin: 'https://fixture.api.cannatrax.net',
      store_id: location.externalId.split('/').last, currency: 'USD', timezone: 'America/New_York',
      source_digest: SecureRandom.hex(16), captured_at: captured_at, orders_json: orders,
      sessions_json: [], controls_json: {})
  end
end
