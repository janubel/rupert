# frozen_string_literal: true

require 'test_helper'

class CashFlowReportTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
    @today = Date.new(2026, 10, 21)
    travel_to @today.in_time_zone.change(hour: 12)
    BankStatementImport.new(bytes: <<~CSV, account_label: 'Operating').import!(filename: 'oct.csv', actor: nil)
      Date,Description,Amount
      2026-10-01,Shopify payout,1200.00
      2026-10-03,Rent,-3000.00
      2026-10-10,NAB deposit,800.00
      2026-10-20,Supplies,-50.00
      2026-09-15,Old payout,500.00
    CSV
    BankStatementLine.where('description IS NOT NULL').find_each do |line|
      line.update_columns(status: 'recorded', review_category: 'processor_deposit') if line.money_in? && line.posted_on.month == 10
    end
    order = Core::Order.create!(source: 'shopify', source_order_id: 's1', occurred_at: Time.zone.parse('2026-10-05 10:00'), gross_cents: 2500, currency: 'USD')
    order.mark_paid!
    Core::Payment.create!(order: order, method: 'card', amount_cents: 2500, paid_at: order.occurred_at, status: 'completed')
    square = Core::Order.create!(source: 'square', source_order_id: 'q1', occurred_at: Time.zone.parse('2026-10-18 15:00'), gross_cents: 1000, currency: 'USD')
    square.mark_paid!
    Core::Payment.create!(order: square, method: 'cash', amount_cents: 1000, paid_at: square.occurred_at, status: 'completed')
    Core::Refund.create!(order: order, method: 'card', amount_cents: 500, refunded_at: Time.zone.parse('2026-10-06 10:00'))
    Finance::Expense.create!(payee: 'Staples', category: 'supplies', amount_cents: 5000, incurred_on: '2026-10-20')
    Finance::Expense.create!(payee: 'Old', category: 'rent', amount_cents: 9999, incurred_on: '2026-08-01')
  end

  teardown do
    travel_back
    Current.reset
  end

  test 'the last 30 days sums bank movement, sales, refunds and spend and compares with the window before' do
    report = CashFlowReport.from_params({ range: '30d' }, today: @today)
    assert_equal Date.new(2026, 9, 22), report.from
    assert_equal :day, report.bucket
    assert_equal 30, report.bucket_starts.size
    assert_equal 200_000, report.cash_in_cents
    assert_equal 305_000, report.cash_out_cents
    assert_equal(-105_000, report.net_cents)
    assert_equal 3500, report.sales_cents
    assert_equal 2, report.sales_count
    assert_equal 500, report.refunds_cents
    assert_equal 5000, report.spend_cents
    assert_equal 200_000, report.processor_deposits_cents
    assert_equal [['Supplies', 5000]], report.spend_by_category
    assert_equal 50_000, report.previous.cash_in_cents, 'the 30 days before hold the September payout'
    assert_equal 0, report.previous.sales_cents
    assert_equal 'Last 30 days', report.range_label
  end

  test 'series line up with the buckets and the running net accumulates' do
    report = CashFlowReport.from_params({ range: '30d' }, today: @today)
    series = report.bank_series
    oct1 = report.bucket_index(Date.new(2026, 10, 1))
    assert_equal 120_000, series[:in][oct1]
    assert_equal 300_000, series[:out][oct1 + 2]
    assert_equal(-105_000, series[:cumulative].last)
    channels = report.channel_series
    assert_equal %w[shopify square], channels.map { |c| c[:key] }, 'channels keep their fixed order'
    assert_equal [1, 2], channels.map { |c| c[:slot] }
    assert_equal 2500, channels.first[:total_cents]
    assert_equal 3500, report.sales_series.sum
    assert_equal 5000, report.spend_series.sum
  end

  test 'long ranges bucket by week or month and custom dates are honoured' do
    assert_equal :week, CashFlowReport.from_params({ range: '90d' }, today: @today).bucket
    year = CashFlowReport.from_params({ range: '12m' }, today: @today)
    assert_equal :month, year.bucket
    assert_equal 12, year.bucket_starts.size
    assert_equal 'Oct 2026', year.bucket_labels.last
    custom = CashFlowReport.from_params({ from: '2026-10-01', to: '2026-10-10' }, today: @today)
    assert_equal 'custom', custom.range_key
    assert_equal 10, custom.span_days
    assert_equal 200_000, custom.cash_in_cents
    assert_equal 300_000, custom.cash_out_cents
    assert_equal 2500, custom.sales_cents
  end

  test 'bad input falls back or is refused in plain words' do
    assert_equal '30d', CashFlowReport.from_params({ from: 'nope', to: '2026-10-10' }, today: @today).range_key
    error = assert_raises(CashFlowReport::Error) { CashFlowReport.from_params({ from: '2026-10-10', to: '2026-10-01' }, today: @today) }
    assert_match(/End date/, error.message)
    assert_raises(CashFlowReport::Error) { CashFlowReport.from_params({ range: '30d', account: 'Nope' }, today: @today) }
  end

  test 'account filter, position and events' do
    BankStatementImport.new(bytes: "Date,Description,Amount\n2026-10-02,Transfer in,100.00\n", account_label: 'Savings').import!(filename: 'sav.csv', actor: nil)
    all = CashFlowReport.from_params({ range: '30d' }, today: @today)
    assert_equal 210_000, all.cash_in_cents
    operating = CashFlowReport.from_params({ range: '30d', account: 'Operating' }, today: @today)
    assert_equal 200_000, operating.cash_in_cents
    assert_equal %w[Operating Savings], operating.accounts
    assert_nil operating.statement_balance, 'no retained statement with a closing balance'
    assert_nil operating.runway_days
    assert operating.average_daily_net_cents.negative?

    doc = BankStatementLine.where(account_label: 'Operating').first.document_id
    ReconciliationEvidence.retain!(bytes: '%PDF-x', filename: 'o.pdf', source: 'bank', kind: 'bank_statement', from: '2026-10-01', to: '2026-10-31',
      metadata: { currency: 'USD', closing_balance_cents: 1_050_000, derived_transaction_document_id: doc })
    fresh = CashFlowReport.from_params({ range: '30d', account: 'Operating' }, today: @today)
    assert_equal 1_050_000, fresh.statement_balance[:cents]
    assert_equal 300, fresh.runway_days, '1,050,000 cents at 3,500 cents a day'

    events = fresh.recent_events(limit: 5)
    assert_equal 5, events.size
    assert events.each_cons(2).all? { |a, b| a[:at] >= b[:at] }, 'newest first'
    assert_includes events.map { |e| e[:kind] }, 'bank_out'
    payload = fresh.to_h
    assert_equal 'day', payload[:range][:bucket]
    assert_equal 30, payload[:bank][:in].size
    assert_equal 2, payload[:channels].size
  end

  test 'another tenant sees nothing' do
    Current.tenant = Tenant.create!(id: 'other-cash', name: 'Other', subdomain: 'other-cash', status: 'active')
    report = CashFlowReport.from_params({ range: '30d' }, today: @today)
    assert_equal 0, report.cash_in_cents
    assert_equal 0, report.sales_cents
    assert_empty report.accounts
    assert_empty report.recent_events
  end
end
