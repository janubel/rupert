# frozen_string_literal: true

require 'test_helper'

class SwipesimpleDaysTest < ActionDispatch::IntegrationTest
  HEADER = 'Transaction #,Date,Type,Amount,Result,Method,Brand,Merchant Account,Tip Amount'
  ROWS = [
    'SYN-1,10/14/2026 9:00 AM,Sale,$50.00,Approved,Swiped,Visa,Example Wholesale,$5.00',
    'SYN-2,10/14/2026 10:00 AM,Sale,$20.00,Approved,Cash,,Example Wholesale,$0.00',
    'SYN-3,10/14/2026 11:00 AM,Sale,$30.00,Approved,Dipped,Mastercard,Example Wholesale,',
    'SYN-4,10/14/2026 12:00 PM,Sale,$99.00,Declined,Dipped,Visa,Example Wholesale,'
  ].freeze

  setup do
    @tenant = tenants(:default_tenant)
    @admin = users(:regular_user)
    travel_to Time.iso8601('2026-10-16T03:00:00Z')
    post login_path, params: { email: @admin.email, password: 'password' }
  end

  teardown do
    travel_back
    Current.reset
  end

  test 'daily close shows totals tender split checks deposit status and the transaction table' do
    import(ROWS)
    get swipesimple_days_path(date: '2026-10-14')
    assert_response :success
    assert_equal 'no-store', response.headers['Cache-Control']
    assert_select 'h1', 'SwipeSimple daily close'
    assert_select '[aria-label="Daily SwipeSimple summary"]', text: /Approved sales.*\$100\.00/m
    assert_select '[aria-label="SwipeSimple totals by account and tender"] tbody tr', 2
    assert_select '[aria-label="SwipeSimple cash and card split"] td', text: '$80.00'
    assert_select '[data-check="unknown_tips"]'
    assert_select '#close-deposit', text: /deposit isn’t available/
    assert_select '.report-table[data-report-table-key-value="swipesimple-day"] tbody tr', 4
    assert_select 'a[href=?]', swipesimple_days_path(date: '2026-10-13'), text: 'Previous day'
    assert_select 'a[href=?]', swipesimple_days_path(date: '2026-10-15'), text: 'Next day'
    assert_select 'form[action=?] input[name=source_digest]', review_swipesimple_days_path
  end

  test 'empty day says no data and links to the connection' do
    get swipesimple_days_path(date: '2026-10-14')
    assert_response :success
    assert_includes response.body, 'That does not prove a zero-sales day'
    assert_select '[data-check="stale"]'
    assert_select 'a[href=?]', pos_connection_path('swipesimple')
    get swipesimple_days_path(date: 'not-a-date')
    assert_redirected_to swipesimple_days_path
  end

  test 'csv lists every transaction of the day with excluded rows marked' do
    import(ROWS)
    get swipesimple_days_path(date: '2026-10-14', format: :csv)
    assert_response :success
    assert_equal 'text/csv', response.media_type
    lines = response.body.lines
    assert_equal 5, lines.size
    assert lines.first.start_with?('BusinessDate,OccurredAt,Account')
    assert(lines.any? { |line| line.include?('SYN-4') && line.include?('no (excluded)') })
    assert(lines.any? { |line| line.include?('SYN-3') && line.include?('30.00,Unknown,yes') })
  end

  test 'local review needs a note for flags and is invalidated when the export changes' do
    import(ROWS)
    get swipesimple_days_path(date: '2026-10-14')
    digest = Nokogiri::HTML(response.body).at_css('input[name=source_digest]')['value']
    assert_no_difference 'SwipesimpleDayReview.unscoped.count' do
      post review_swipesimple_days_path, params: { date: '2026-10-14', source_digest: digest, note: '' }
      post review_swipesimple_days_path, params: { date: '2026-10-14', source_digest: 'stale', note: 'Checked' }
    end
    assert_difference 'SwipesimpleDayReview.unscoped.count', 1 do
      post review_swipesimple_days_path, params: { date: '2026-10-14', source_digest: digest, note: 'Tip for SYN-3 confirmed with staff.' }
    end
    assert_redirected_to swipesimple_days_path(date: Date.new(2026, 10, 14))
    follow_redirect!
    assert_select '#close-review', text: /Current version reviewed/
    Current.tenant = @tenant
    review = SwipesimpleDayReview.sole
    assert_equal [@admin.id, digest, 'Tip for SYN-3 confirmed with staff.'], [review.reviewed_by_id, review.reviewed_digest, review.review_note]
    assert SwipesimpleDayClose.new(Date.new(2026, 10, 14)).reviewed?

    import(ROWS.map { |row| row.start_with?('SYN-1,') ? row.sub('$50.00', '$55.00') : row }, exported_at: '2026-10-15T22:30:00-04:00')
    assert_not SwipesimpleDayClose.new(Date.new(2026, 10, 14)).reviewed?
    get swipesimple_days_path(date: '2026-10-14')
    assert_select '#close-review', text: /Review needed.*changed since/m
    post review_swipesimple_days_path, params: { date: '2026-10-14', source_digest: digest, note: 'Old view' }
    assert_equal digest, review.reload.reviewed_digest, 'a review of the old data cannot be recorded'
  end

  test 'sales readers can view but not review, others are refused' do
    import(ROWS)
    reader = User.create!(email: 'ss-reader@example.invalid', password: 'password123', role: 'reader', tenant: @tenant)
    switch_to(reader)
    get swipesimple_days_path(date: '2026-10-14')
    assert_response :success
    assert_select '#close-review', count: 0
    post review_swipesimple_days_path, params: { date: '2026-10-14', source_digest: 'x', note: 'x' }
    assert_response :forbidden

    stock = User.create!(email: 'ss-stock@example.invalid', password: 'password123', role: 'inventory_employee', tenant: @tenant)
    switch_to(stock)
    get swipesimple_days_path(date: '2026-10-14')
    assert_response :redirect
    assert_equal 0, SwipesimpleDayReview.unscoped.count
  end

  test 'sits in the Sell area next to C-Trax daily close and is linked from the close pages' do
    assert_equal 'sell', ModuleRegistry.area_key_for('swipesimple_days')
    keys = ModuleRegistry.nav_for(@admin).map(&:key)
    assert_equal keys.index('ctrax_days') + 1, keys.index('swipesimple_days')
    reader = User.create!(email: 'ss-nav@example.invalid', password: 'password123', role: 'inventory_employee', tenant: @tenant)
    refute_includes ModuleRegistry.nav_for(reader).map(&:key), 'swipesimple_days'

    get swipesimple_days_path
    assert_select 'nav[aria-label="Retail workspace"] a[aria-current="page"]', 'SwipeSimple daily close'
    get ctrax_days_path(date: '2026-10-14')
    assert_select 'a[href=?]', swipesimple_days_path(date: '2026-10-14')
    import(ROWS)
    get daily_reconciliations_path(day: '2026-10-14')
    assert_select 'a[href=?]', swipesimple_days_path(date: '2026-10-14')
  end

  private

  def switch_to(user)
    delete logout_path
    post login_path, params: { email: user.email, password: 'password123' }
  end

  def import(rows, exported_at: '2026-10-15T22:00:00-04:00')
    Current.tenant = @tenant
    csv = ([HEADER] + rows).join("\n") + "\n"
    options = { kind: 'transactions', merchant_account: 'Example Wholesale', currency: 'USD',
      source_timezone: 'America/New_York', exported_at: exported_at }
    prepared = SwipesimpleReportImporter.preview(csv, options)
    SwipesimpleReportImporter.import!(csv, options, expected_fingerprint: prepared.fingerprint)
  end
end
