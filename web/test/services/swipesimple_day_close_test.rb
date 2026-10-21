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
    refute_includes close.checks.map(&:key), :declines, 'a tiny day never fires the decline flag'
  end

  test 'decline flag fires at 5 percent of attempts once there are enough attempts' do
    approved = (1..19).map { |n| "SYN-A#{n},10/14/2026 9:#{format('%02d', n)} AM,Sale,$1.00,Approved,Swiped,Visa,Example Wholesale,$0.00" }
    import(approved + ['SYN-D1,10/14/2026 10:00 AM,Sale,$1.00,Declined,Swiped,Visa,Example Wholesale,'])
    assert_includes SwipesimpleDayClose.new(Date.new(2026, 10, 14)).checks.map(&:key), :declines
    more = (20..39).map { |n| "SYN-A#{n},10/14/2026 11:#{format('%02d', n)} AM,Sale,$1.00,Approved,Swiped,Visa,Example Wholesale,$0.00" }
    import(approved + more + ['SYN-D1,10/14/2026 10:00 AM,Sale,$1.00,Declined,Swiped,Visa,Example Wholesale,'], exported_at: '2026-10-15T22:30:00-04:00')
    refute_includes SwipesimpleDayClose.new(Date.new(2026, 10, 14)).checks.map(&:key), :declines, '1 of 40 is 2.5%'
    small = (1..8).map { |n| "SYN-S#{n},10/13/2026 9:#{format('%02d', n)} AM,Sale,$1.00,Approved,Swiped,Visa,Example Wholesale,$0.00" }
    import(small + ['SYN-SD,10/13/2026 10:00 AM,Sale,$1.00,Declined,Swiped,Visa,Example Wholesale,'], exported_at: '2026-10-15T22:40:00-04:00')
    refute_includes SwipesimpleDayClose.new(Date.new(2026, 10, 13)).checks.map(&:key), :declines, 'fewer than 10 attempts'
  end

  test 'chosen funding merchant matches the first later deposit and groups a weekend into one comparison' do
    card = ->(n, day, amount) { "SYN-L#{n},#{day} 1:00 PM,Sale,$#{amount},Approved,Swiped,Visa,Example Wholesale,$0.00" }
    import([card.call(1, '10/08/2026', '10.00'), card.call(2, '10/09/2026', '20.00'), card.call(3, '10/10/2026', '30.00'),
      card.call(4, '10/11/2026', '40.00'), card.call(5, '10/12/2026', '50.00'), card.call(7, '10/14/2026', '7.00'),
      'SYN-L6,10/12/2026 2:00 PM,Sale,$5.00,Approved,Cash,,Example Wholesale,$0.00'])
    retail = '000000004321'
    deposit_report('daily_deposits_csv', '2026-10-01', '2026-10-31', 1.hour.ago,
      [['2026-10-09', '10.00'], ['2026-10-12', '60.00'], ['2026-10-12', '30.00'], ['2026-10-13', '49.50']], merchant: retail)
    deposit_report('deposits', '2026-10-12', '2026-10-12', 3.hours.ago, [['2026-10-12', '500.00']], key: 'deposits', merchant: retail)
    deposit_report('daily_deposits_csv', '2026-10-01', '2026-10-31', 1.hour.ago, [['2026-10-09', '999.00']], merchant: '000000008765')

    assert_nil SwipesimpleDayClose.new(Date.new(2026, 10, 9)).deposit_merchant, 'no merchant is chosen by default'
    TenantSettings.set(:swipesimple_deposit_merchant, retail)

    thursday = SwipesimpleDayClose.new(Date.new(2026, 10, 8)).deposit_match
    assert_equal [Date.new(2026, 10, 9), [Date.new(2026, 10, 8)], 1000, 0], [thursday.deposit_date, thursday.business_days, thursday.amount_cents, thursday.difference_cents]

    weekend = (9..11).map { |day| SwipesimpleDayClose.new(Date.new(2026, 10, day)) }
    weekend.each do |close|
      match = close.deposit_match
      assert_equal Date.new(2026, 10, 12), match.deposit_date
      assert_equal (Date.new(2026, 10, 9)..Date.new(2026, 10, 11)).to_a, match.business_days
      assert_equal [9000, 9000, 0], [match.amount_cents, match.card_net_cents, match.difference_cents], 'newest snapshot only, never the overlapping $500'
      assert_includes close.checks.map(&:key), :grouped_deposit
      refute_includes close.checks.map(&:key), :deposit_difference
    end

    monday = SwipesimpleDayClose.new(Date.new(2026, 10, 12))
    assert_equal [Date.new(2026, 10, 13), [Date.new(2026, 10, 12)], 5000, -50], monday.deposit_match.to_h.values_at(:deposit_date, :business_days, :card_net_cents, :difference_cents)
    assert(monday.checks.any? { |item| item.key == :deposit_difference && item.level == :warn && item.message.include?('••4321') && item.message.include?('-$0.50') })

    matches = (8..12).map { |day| SwipesimpleDayClose.new(Date.new(2026, 10, day)).deposit_match }
    by_deposit = matches.group_by(&:deposit_date).transform_values { |list| list.map(&:business_days).uniq }
    assert(by_deposit.values.all? { |sets| sets.one? }, 'every day of a deposit sees the same group')
    days = by_deposit.values.flatten
    assert_equal days.uniq, days, 'no business day is counted against two deposits'

    assert_nil SwipesimpleDayClose.new(Date.new(2026, 10, 14)).deposit_match
    assert_includes SwipesimpleDayClose.new(Date.new(2026, 10, 14)).checks.map(&:key), :no_deposit
  end

  test 'daily close summary uses SwipeSimple cash and card tenders instead of calling everything credit' do
    import(ROWS + ['SYN-U,10/14/2026 3:00 PM,Sale,$4.00,Approved,On File,,Example Wholesale,$0.00'])
    row = DailyCloseSummary.new(day: Date.new(2026, 10, 14)).swipesimple_row
    assert_equal [9200, 2000, 6800], [row.net, row.cash, row.credit]
    assert_includes row.notes, '$4.00 has no identified tender'
    refute_includes row.notes, 'does not report tax or cash'
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

  def deposit_report(kind, from, to, observed, records, key: 'data', merchant: '000000001234')
    IrisReport.create!(api_origin: 'https://fixture.iriscrm.com', merchant_number: merchant, report_kind: kind,
      window_from: from, window_to: to, status: 'complete', observed_at: observed,
      payload_json: { 'currency' => nil, key => records.map { |date, amount| { 'date' => date, 'amount' => amount, 'batch' => 'SYN' } } }.to_json)
  end
end
