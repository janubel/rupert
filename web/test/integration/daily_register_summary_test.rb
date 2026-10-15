# frozen_string_literal: true

require 'test_helper'

class DailyRegisterSummaryTest < ActionDispatch::IntegrationTest
  setup do
    Current.tenant = tenants(:default_tenant)
    @tenant = Current.tenant
    @day = Date.new(2026, 10, 14)
    user = User.create!(tenant: @tenant, email: 'register-report@example.com', password: 'password123', role: 'reporting')
    post login_path, params: { email: user.email, password: 'password123' }
  end

  teardown { Current.reset }

  test 'summary dates payments and refunds by their own events and keeps currencies separate' do
    old = order_at(@day - 1)
    old.payments.create!(method: 'cash', amount_cents: 1000, paid_at: @day.noon)
    old.refunds.create!(method: 'cash', amount_cents: 200, refunded_at: @day.noon)
    today = order_at(@day)
    today.payments.create!(method: 'card', amount_cents: 1000, paid_at: (@day + 1).noon)
    euro = order_at(@day, currency: 'EUR')
    euro.payments.create!(method: 'card', amount_cents: 1000, paid_at: @day.noon)
    summary = DailyRegisterSummary.new(day: @day.iso8601)
    usd = summary.rows.find { |row| row[:currency] == 'USD' }
    eur = summary.rows.find { |row| row[:currency] == 'EUR' }
    assert_equal 1, usd[:orders]
    assert_equal({ 'cash' => 1000 }, usd[:tenders])
    assert_equal 200, usd[:refund_cents]
    assert_equal({ 'card' => 1000 }, eur[:tenders])
    assert_includes summary.csv, 'Unavailable'

    get register_summary_reports_path, params: { day: @day.iso8601 }
    assert_response :success
    assert_select 'h1', 'Daily register summary'
    assert_select 'td', 'EUR'
  end

  test 'source location tenant filters and missing tender coverage are explicit' do
    own = order_at(@day, source: 'square', location_id: 'shop-register')
    own.payments.create!(method: 'card', amount_cents: 1000, paid_at: @day.noon, status: 'pending')
    order_at(@day, source: 'shopify')
    other = Tenant.create!(name: 'Foreign store', subdomain: 'register-foreign')
    Current.tenant = other
    foreign = order_at(@day, tenant_id: other.id)
    foreign.payments.create!(tenant_id: other.id, method: 'cash', amount_cents: 90000, paid_at: @day.noon)
    Current.tenant = @tenant
    summary = DailyRegisterSummary.new(day: @day.iso8601, source: 'square', location_id: 'shop-register')
    assert_equal 1, summary.rows.length
    assert_equal 1, summary.missing_payment_orders
    assert_empty summary.rows.first[:tenders]
    get register_summary_reports_path(format: :csv), params: { day: @day.iso8601, source: 'square' }
    assert_response :success
    assert_includes response.body, 'shop-register'
    refute_includes response.body, '90000'
  end

  test 'CSV neutralizes spreadsheet formulas in imported string columns' do
    values = ['=HYPERLINK("https://example.com")', '+SUM(1,2)', '-1+2', '@SUM(1,2)', "\t=1+2", "\r=1+2", " \n=1+2"]
    values.each do |value|
      order_at(@day, currency: value, source: value, location_id: value)
    end
    get register_summary_reports_path(format: :csv), params: { day: @day.iso8601 }
    assert_response :success
    rows = CSV.parse(response.body, headers: true)
    values.each do |value|
      row = rows.find { |item| item['Currency'] == "'#{value}" }
      assert row, "expected #{value.inspect} to be neutralized"
      assert_equal "'#{value}", row['Source']
      assert_equal "'#{value}", row['Location']
      assert_equal '1000', row['Order total cents']
    end
  end

  test 'register summary and CSV require reporting permission' do
    User.find_by!(email: 'register-report@example.com').update!(role: 'cashier')
    get register_summary_reports_path, params: { day: @day.iso8601 }
    assert_redirected_to root_path
    get register_summary_reports_path(format: :csv), params: { day: @day.iso8601 }
    assert_redirected_to root_path
  end

  private

  def order_at(day, **attributes)
    order = Core::Order.create!({ source: 'shopify', source_order_id: SecureRandom.uuid,
      occurred_at: day.noon, gross_cents: 1000, tax_cents: 100, currency: 'USD' }.merge(attributes))
    order.mark_paid!
    order
  end
end
