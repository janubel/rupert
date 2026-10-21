# frozen_string_literal: true

require 'test_helper'

class SwipesimpleDayCloseTest < ActiveSupport::TestCase
  HEADER = 'Transaction #,Date,Type,Amount,Result,Method,Brand,Merchant Account,Tip Amount'
  ROWS = [
    'SYN-1,10/14/2026 9:00 AM,Sale,$50.00,Approved,Swiped,Visa,Example Wholesale,$5.00',
    'SYN-2,10/14/2026 10:00 AM,Sale,$20.00,Approved,Cash,,Example Wholesale,$0.00',
    'SYN-3,10/14/2026 11:00 AM,Sale,$30.00,Approved,Dipped,Mastercard,Example Wholesale,',
    'SYN-4,10/14/2026 12:00 PM,Sale,$99.00,Declined,Dipped,Visa,Example Wholesale,',
    'SYN-5,10/14/2026 1:00 PM,Sale,$15.00,Voided,Keyed,Visa,Example Wholesale,',
    'SYN-0,10/12/2026 3:00 PM,Sale,$12.00,Approved,Tapped,Visa,Example Wholesale,$2.00',
    'SYN-0,10/14/2026 2:00 PM,Refund,$12.00,Approved,Tapped,Visa,Example Wholesale,$0.00',
    'SYN-6,10/15/2026 12:30 AM,Sale,$7.00,Approved,Cash,,Example Wholesale,$0.00',
    'SYN-7,10/13/2026 11:59 PM,Sale,$8.00,Approved,Cash,,Example Wholesale,$0.00'
  ].freeze

  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    travel_to Time.iso8601('2026-10-16T03:00:00Z')
  end

  teardown do
    travel_back
    Current.reset
  end

  test 'totals by account and tender keep cash and card apart and exclude declined and voided rows' do
    import(ROWS)
    close = SwipesimpleDayClose.new(Date.new(2026, 10, 14))
    assert_equal :covered, close.coverage
    assert_equal 6, close.rows.size, 'the day runs midnight to midnight America/New_York'
    card = close.groups.find { |group| group.tender == 'card' }
    cash = close.groups.find { |group| group.tender == 'cash' }
    assert_equal [2, 8000, 1, 1200, 6800], [card.sale_count, card.sale_cents, card.refund_count, card.refund_cents, card.net_cents]
    assert_equal [1, 1, 0], [card.declined_count, card.voided_count, card.other_excluded_count]
    assert_equal [1, 2000, 2000, 0], [cash.sale_count, cash.sale_cents, cash.net_cents, cash.tip_cents]
    assert_equal 6800, close.card_net_cents
    split = close.tender_split.first
    assert_equal [2000, 6800, nil, 8800], split.values_at(:cash, :card, :unknown, :total)
    assert_equal 2, close.excluded.size
    assert_includes close.checks.map(&:key), :declines
  end

  test 'unknown tips stay unknown instead of zero' do
    import(ROWS)
    close = SwipesimpleDayClose.new(Date.new(2026, 10, 14))
    card = close.groups.find { |group| group.tender == 'card' }
    assert_nil card.tip_cents
    assert_equal 1, card.missing_tip_rows
    assert_equal ['SYN-3'], close.unknown_tip_rows.map(&:source_number)
    assert_includes close.checks.map(&:key), :unknown_tips
    assert_includes close.to_csv, ',30.00,Unknown,yes'
  end

  test 'refunds of an earlier day sale are flagged and lower this day only' do
    import(ROWS)
    close = SwipesimpleDayClose.new(Date.new(2026, 10, 14))
    refund = close.refunds.sole
    assert refund[:earlier_day]
    assert_equal Date.new(2026, 10, 12), refund[:sale].occurred_at.in_time_zone('America/New_York').to_date
    assert(close.checks.any? { |item| item.key == :earlier_refund && item.message.include?('Oct 12, 2026') })
    earlier = SwipesimpleDayClose.new(Date.new(2026, 10, 12))
    assert_equal 1200, earlier.card_net_cents
    assert_empty earlier.refunds
  end

  test 'days with no data are not zero-sales days' do
    close = SwipesimpleDayClose.new(Date.new(2026, 10, 14))
    assert_equal :missing, close.coverage
    assert_empty close.groups
    assert_nil close.card_net_cents
    assert_includes close.checks.map(&:key), :stale
    import(ROWS)
    quiet = SwipesimpleDayClose.new(Date.new(2026, 10, 1))
    assert_equal :covered, quiet.coverage
    assert_equal [:no_rows], quiet.checks.map(&:key)
    today = SwipesimpleDayClose.new(Date.new(2026, 10, 15))
    assert_equal :partial, today.coverage
    assert_equal :future, SwipesimpleDayClose.new(Date.new(2026, 10, 17)).coverage
  end

  test 'deposit uses one newest covering snapshot per merchant and never sums overlapping windows' do
    import(ROWS)
    close = SwipesimpleDayClose.new(Date.new(2026, 10, 14))
    assert_empty close.deposits_with_records
    assert_includes close.checks.map(&:key), :no_deposit
    deposit_report('daily_deposits_csv', '2026-10-01', '2026-10-31', 1.hour.ago, [['2026-10-14', '66.50'], ['2026-10-14', '0.25'], ['2026-10-13', '9.00']])
    deposit_report('deposits', '2026-10-14', '2026-10-14', 2.hours.ago, [['2026-10-14', '1000.00']], key: 'deposits')
    close = SwipesimpleDayClose.new(Date.new(2026, 10, 14))
    deposit = close.deposits_with_records.sole
    assert_equal 6675, deposit.amount_cents
    assert_equal 'MID ••1234', deposit.merchant_label
    assert_equal(-125, close.deposit_difference_cents(deposit))
    refute_includes close.checks.map(&:key), :no_deposit
  end

  test 'source digest changes when a later export changes the day' do
    import(ROWS)
    close = SwipesimpleDayClose.new(Date.new(2026, 10, 14))
    digest = close.source_digest
    assert_equal digest, SwipesimpleDayClose.new(Date.new(2026, 10, 14)).source_digest
    import(ROWS + ['SYN-8,10/15/2026 9:00 PM,Sale,$3.00,Approved,Cash,,Example Wholesale,$0.00'], exported_at: '2026-10-15T22:30:00-04:00')
    assert_equal digest, SwipesimpleDayClose.new(Date.new(2026, 10, 14)).source_digest, 'another day changing does not invalidate this one'
    changed = ROWS.map { |row| row.start_with?('SYN-1,') ? row.sub('Approved', 'Voided') : row }
    import(changed, exported_at: '2026-10-15T22:45:00-04:00')
    assert_not_equal digest, SwipesimpleDayClose.new(Date.new(2026, 10, 14)).source_digest
  end

  private

  def import(rows, exported_at: '2026-10-15T22:00:00-04:00')
    csv = ([HEADER] + rows).join("\n") + "\n"
    options = { kind: 'transactions', merchant_account: 'Example Wholesale', currency: 'USD',
      source_timezone: 'America/New_York', exported_at: exported_at }
    prepared = SwipesimpleReportImporter.preview(csv, options)
    SwipesimpleReportImporter.import!(csv, options, expected_fingerprint: prepared.fingerprint)
  end

  def deposit_report(kind, from, to, observed, records, key: 'data')
    IrisReport.create!(api_origin: 'https://fixture.iriscrm.com', merchant_number: '000000001234', report_kind: kind,
      window_from: from, window_to: to, status: 'complete', observed_at: observed,
      payload_json: { 'currency' => nil, key => records.map { |date, amount| { 'date' => date, 'amount' => amount, 'batch' => 'SYN' } } }.to_json)
  end
end
