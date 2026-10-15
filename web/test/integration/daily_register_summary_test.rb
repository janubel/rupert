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

  test 'refunds and net tenders retain method source location and currency pools' do
    old = order_at(@day - 2, source: 'square', location_id: 'register-a')
    old.payments.create!(method: 'cash', amount_cents: 600, paid_at: @day.noon)
    old.payments.create!(method: 'card', amount_cents: 400, paid_at: @day.noon)
    old.refunds.create!(method: 'cash', amount_cents: 100, refunded_at: @day.noon)
    old.refunds.create!(method: 'card', amount_cents: 200, refunded_at: @day.noon)
    old.refunds.create!(method: 'store_credit', amount_cents: 50, refunded_at: @day.noon)
    discarded = old.refunds.create!(method: 'cash', amount_cents: 100, refunded_at: @day.noon)
    discarded.discard!
    old.refunds.create!(method: 'cash', amount_cents: 70, refunded_at: (@day + 1).noon)
    euro = order_at(@day, source: 'square', location_id: 'register-a', currency: 'EUR')
    euro.payments.create!(method: 'cash', amount_cents: 1000, paid_at: @day.noon)
    second = order_at(@day, source: 'square', location_id: 'register-b')
    second.payments.create!(method: 'cash', amount_cents: 1000, paid_at: @day.noon)
    summary = DailyRegisterSummary.new(day: @day.iso8601, source: 'square', location_id: 'register-a')
    row = summary.rows.find { |item| item[:currency] == 'USD' }
    assert_equal 0, row[:orders]
    assert_equal({ 'cash' => 100, 'card' => 200, 'store_credit' => 50 }, row[:refund_tenders])
    assert_equal({ 'cash' => 500, 'card' => 200, 'store_credit' => -50 }, row[:net_tenders])
    assert_equal 650, row[:net_tender_cents]
    assert_equal 2, summary.rows.length
    csv = CSV.parse(summary.csv, headers: true).find { |item| item['Currency'] == 'USD' }
    assert_equal '100', csv['Cash refund cents']
    assert_equal '200', csv['Card refund cents']
    assert_equal '50', csv['Other tender refund cents']
    assert_equal '-50', csv['Net other tender cents']
    get register_summary_reports_path, params: { day: @day.iso8601, source: 'square', location_id: 'register-a' }
    assert_response :success
    assert_select 'td', 'Store credit'
    assert_select 'td', '-0.50'
    refute_includes response.body, 'register-b'
  end

  test 'coverage compares lifetime completed totals and keeps unknown amounts unavailable' do
    missing = order_at(@day, source: 'swipesimple')
    missing.payments.create!(method: 'cash', amount_cents: 1000, paid_at: @day.noon, status: 'pending')
    partial = order_at(@day, source: 'swipesimple')
    partial.payments.create!(method: 'cash', amount_cents: 200, paid_at: @day.noon)
    partial.payments.create!(method: 'card', amount_cents: 300, paid_at: @day.noon)
    excess = order_at(@day, source: 'swipesimple')
    excess.payments.create!(method: 'card', amount_cents: 1200, paid_at: @day.noon)
    later = order_at(@day, source: 'swipesimple')
    later.payments.create!(method: 'cash', amount_cents: 1000, paid_at: (@day + 1).noon)
    unknown = order_at(@day, source: 'swipesimple', gross_cents: nil, tax_cents: nil)
    payment = unknown.payments.create!(method: 'card', amount_cents: 1000, paid_at: @day.noon)
    payment.update_columns(amount_cents: nil)
    summary = DailyRegisterSummary.new(day: @day.iso8601, source: 'swipesimple')
    assert_equal 1, summary.coverage[:missing_payment_orders]
    assert_equal 1, summary.coverage[:incomplete_payment_orders]
    assert_equal 1, summary.coverage[:overcovered_payment_orders]
    assert_equal 1, summary.coverage[:unknown_amount_orders]
    assert_equal 1, summary.coverage[:missing_tax_orders]
    row = summary.rows.first
    assert_nil row[:order_total_cents]
    assert_nil row[:tax_cents]
    assert_nil row[:tenders]['card']
    assert_nil row[:net_tenders]['card']
    assert_nil row[:net_tender_cents]
    csv = CSV.parse(summary.csv, headers: true).first
    %w[Order\ total\ cents Recorded\ tax\ cents Card\ cents Net\ card\ cents Tenders\ less\ refunds\ cents].each do |column|
      assert_equal 'Unavailable', csv[column], column
    end
    get register_summary_reports_path, params: { day: @day.iso8601, source: 'swipesimple' }
    assert_response :success
    assert_includes response.body, 'across all payment dates'
    assert_includes response.body, 'Original source-date provenance is unavailable'
    assert_select 'td', 'Unavailable'
  end

  test 'unsettled and cancelled orders cannot contribute inferred completed tenders' do
    unsettled = Core::Order.create!(source: 'shopify', source_order_id: SecureRandom.uuid, occurred_at: @day.noon,
      gross_cents: 3000, currency: 'USD')
    unsettled.payments.create!(method: 'card', amount_cents: 3000, paid_at: @day.noon)
    cancelled = Core::Order.create!(source: 'shopify', source_order_id: SecureRandom.uuid, occurred_at: @day.noon,
      gross_cents: 4000, currency: 'USD')
    cancelled.cancel!
    cancelled.payments.create!(method: 'card', amount_cents: 4000, paid_at: @day.noon)
    summary = DailyRegisterSummary.new(day: @day.iso8601, source: 'shopify')
    assert_equal 2, summary.coverage[:excluded_payment_records]
    assert_equal 0, summary.rows.first[:orders]
    assert_empty summary.rows.first[:tenders]
    csv = CSV.parse(summary.csv, headers: true).first
    assert_equal '2', csv['Excluded unsettled payment records']
    assert_equal '0', csv['Card cents']
    assert_includes csv['Tender provenance'], 'Inferred'
    get register_summary_reports_path, params: { day: @day.iso8601 }
    assert_response :success
    assert_includes response.body, 'not collection'
    assert_includes response.body, 'Shopify tenders are inferred'
  end

  test 'freshness uses confirmed source successes and distinguishes completion from event dates' do
    csv_order = order_at(@day - 20, source: 'swipesimple')
    csv_order.payments.create!(method: 'cash', amount_cents: 1000, paid_at: (@day - 20).noon)
    square_direct = sync_run(source: 'square', finished: @day.noon - 5.hours)
    full_square = sync_run(source: 'all', finished: @day.noon - 4.hours,
      details: { shopify: { products: 2, variants: 3 }, square: { locations: 1, orders: 0 } }.to_json)
    full_skip = sync_run(source: 'all', finished: @day.noon - 3.hours,
      details: { shopify: { products: 2, variants: 3 }, square: { status: 'skipped' } }.to_json)
    sync_run(source: 'all', finished: @day.noon - 2.hours, details: 'invalid-private-details')
    sync_run(source: 'square', finished: @day.noon, status: 'failed')
    csv_run = sync_run(source: 'swipesimple', finished: @day.noon, mode: '=IMPORT_MODE')
    foreign = Tenant.create!(name: 'Foreign freshness', subdomain: 'foreign-freshness')
    Current.tenant = foreign
    sync_run(source: 'square', finished: @day.noon + 1.hour)
    Current.tenant = @tenant
    summary = DailyRegisterSummary.new(day: @day.iso8601)
    assert_equal full_square.finishedAt, summary.source_freshness['square'][:finished_at]
    refute_equal square_direct.finishedAt, summary.source_freshness['square'][:finished_at]
    assert_equal full_skip.finishedAt, summary.source_freshness['shopify'][:finished_at]
    assert_equal csv_run.finishedAt, summary.source_freshness['swipesimple'][:finished_at]
    assert_equal csv_order.occurred_at, summary.source_freshness['swipesimple'][:order_at]
    assert_equal csv_order.occurred_at, summary.source_freshness['swipesimple'][:payment_at]
    get register_summary_reports_path, params: { day: @day.iso8601 }
    assert_response :success
    assert_includes response.body, 'Importing an old CSV today does not establish'
    refute_includes response.body, 'invalid-private-details'
    csv_summary = DailyRegisterSummary.new(day: (@day - 20).iso8601, source: 'swipesimple')
    csv = CSV.parse(csv_summary.csv, headers: true).first
    assert_equal "'=IMPORT_MODE", csv['Import mode']
    assert_equal csv_run.finishedAt.iso8601, csv['Latest source import completion']
    assert_equal csv_order.occurred_at.iso8601, csv['Latest stored eligible order event']
  end

  test 'CSV never claims source-confirmed history without a relevant successful run' do
    order_at(@day, source: 'square')
    summary = DailyRegisterSummary.new(day: @day.iso8601, source: 'square')
    csv = CSV.parse(summary.csv, headers: true).first
    assert_equal 'Unavailable', csv['Latest source import completion']
    assert_equal 'No source-confirmed successful import recorded', csv['Import history coverage']
    sync_run(source: 'all', finished: @day.noon,
      details: { shopify: { products: 0, variants: 0 }, square: { status: 'skipped' } }.to_json)
    summary = DailyRegisterSummary.new(day: @day.iso8601, source: 'square')
    assert_nil summary.source_freshness['square'][:finished_at]
    assert_equal 'No source-confirmed successful import recorded', CSV.parse(summary.csv, headers: true).first['Import history coverage']
  end

  test 'bounded full-sync scan exposes uncertainty rather than claiming stale direct success is latest' do
    order_at(@day, source: 'square')
    older = sync_run(source: 'square', finished: (@day - 30).noon)
    (DailyRegisterSummary::FULL_SYNC_HISTORY_LIMIT + 1).times do |index|
      sync_run(source: 'all', finished: @day.noon - index.minutes,
        details: { shopify: { products: 0, variants: 0 }, square: { status: 'skipped' } }.to_json)
    end
    summary = DailyRegisterSummary.new(day: @day.iso8601, source: 'square')
    assert_equal older.finishedAt, summary.source_freshness['square'][:finished_at]
    assert summary.source_freshness['square'][:history_limited]
    assert_includes CSV.parse(summary.csv, headers: true).first['Import history coverage'], 'latest source success unconfirmed'
    newer = sync_run(source: 'square', finished: @day.noon + 1.hour)
    summary = DailyRegisterSummary.new(day: @day.iso8601, source: 'square')
    assert_equal newer.finishedAt, summary.source_freshness['square'][:finished_at]
    refute summary.source_freshness['square'][:history_limited]
  end

  test 'day boundaries follow report timezone while event timestamps retain explicit offsets' do
    Time.use_zone('America/New_York') do
      included = order_at(@day, source: 'square')
      included.update_columns(occurred_at: Time.iso8601('2026-10-15T03:59:59Z'))
      included.payments.create!(method: 'cash', amount_cents: 1000, paid_at: Time.iso8601('2026-10-15T03:59:59Z'))
      excluded = order_at(@day, source: 'square')
      excluded.update_columns(occurred_at: Time.iso8601('2026-10-15T04:00:00Z'))
      excluded.payments.create!(method: 'cash', amount_cents: 1000, paid_at: Time.iso8601('2026-10-15T04:00:00Z'))
      summary = DailyRegisterSummary.new(day: @day.iso8601, source: 'square')
      assert_equal 1, summary.rows.first[:orders]
      assert_equal({ 'cash' => 1000 }, summary.rows.first[:tenders])
      assert_equal 'America/New_York', CSV.parse(summary.csv, headers: true).first['Day timezone']
    end
  end

  test 'cross-tenant associations do not inflate tender or coverage values' do
    own = order_at(@day, source: 'square')
    foreign = Tenant.create!(name: 'Foreign association', subdomain: 'foreign-association')
    Current.tenant = foreign
    foreign_order = order_at(@day, source: 'square')
    Core::Payment.new(order_id: own.id, tenant_id: foreign.id, method: 'card', amount_cents: 90000, paid_at: @day.noon).save!(validate: false)
    Current.tenant = @tenant
    Core::Payment.new(order_id: foreign_order.id, tenant_id: @tenant.id, method: 'card', amount_cents: 80000, paid_at: @day.noon).save!(validate: false)
    summary = DailyRegisterSummary.new(day: @day.iso8601, source: 'square')
    assert_equal 1, summary.coverage[:missing_payment_orders]
    assert_empty summary.rows.first[:tenders]
    refute_includes summary.csv, '90000'
    refute_includes summary.csv, '80000'
  end

  private

  def sync_run(source:, finished:, status: 'success', details: nil, mode: 'manual')
    SyncRun.create!(source: source, mode: mode, status: status, startedAt: finished - 5.minutes,
      finishedAt: finished, details: details)
  end

  def order_at(day, **attributes)
    order = Core::Order.create!({ source: 'shopify', source_order_id: SecureRandom.uuid,
      occurred_at: day.noon, gross_cents: 1000, tax_cents: 100, currency: 'USD' }.merge(attributes))
    order.mark_paid!
    order
  end
end
