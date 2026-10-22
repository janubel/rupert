# frozen_string_literal: true

require 'test_helper'
require 'csv'
require_relative '../support/ctrax_daily_items_fixture'

class CtraxDailyItemsPageTest < ActionDispatch::IntegrationTest
  include CtraxDailyItemsFixture

  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    @user = users(:regular_user)
    build_ctrax_items_fixture
    post login_path, params: { email: @user.email, password: 'password' }
    Current.tenant = @tenant
  end

  teardown { Current.reset }

  def assert_row(selector, pattern)
    texts = css_select(selector).map { |node| node.text.squish }
    assert texts.any? { |text| text.match?(pattern) }, "No #{selector} matches #{pattern.inspect}: #{texts.inspect}"
  end

  test 'store close shows items sold, tie-out and items missing from the catalog' do
    get ctrax_day_path(@downtown_day)
    assert_response :success
    assert_select 'a[href="#close-items"]'
    assert_select '#close-tie-out', text: /Items reconcile to sales/
    assert_select '#close-tie-out tbody tr', count: 3
    assert_select '#close-items .report-table[data-controller=report-table]'
    assert_select '#close-items .report-table tbody tr', count: 4
    assert_row '#close-items .report-table tbody tr', /Gummies Mango · 10 count.*HH-GUM-10.*Edibles.*\$50.00/m
    assert_row '#close-items .report-table tbody tr', /Hemp Wick · Roll.*Unknown.*1 receipt with refunds/m
    assert_select '#close-items th', text: 'Stores', count: 0
    assert_select '#close-not-in-catalog li', count: 3
    assert_row '#close-not-in-catalog li', /House Pre-Roll · 1 g.*Not in Rupert catalog/m
    assert_row '#close-not-in-catalog li', /Blue Dream Flower · 3.5 g.*Possible match: Blue Dream Flower · 3.5 g/m
    assert_select '#close-not-in-catalog a[href=?]', stock_comparison_path(ctrax_location_id: @downtown.id, filter: 'unmatched')
    assert_select 'a[href=?]', items_ctrax_days_path(date: @date, location_id: @downtown.id, format: :csv)
  end

  test 'all stores page combines the date and exports CSV' do
    get ctrax_days_path(date: @date)
    assert_select 'a[href=?]', items_ctrax_days_path(date: @date)
    get items_ctrax_days_path(date: @date)
    assert_response :success
    assert_select 'h1', 'Items sold · All stores'
    assert_select '#close-items th', text: 'Stores'
    assert_select '#close-tie-out article', count: 3
    assert_row '#close-items .report-table tbody tr', /Gummies Mango · 10 count.*Downtown, Uptown/m

    get items_ctrax_days_path(date: @date, format: :csv)
    assert_response :success
    assert_equal 'text/csv', response.media_type
    assert_match 'ctrax-items-2026-10-14-all-stores.csv', response.headers['Content-Disposition']
    rows = CSV.parse(response.body, headers: true)
    assert_equal ['3', 'Downtown; Uptown'], rows.find { |r| r['C-Trax variant ID'] == '101' }.values_at('Quantity (units)', 'Stores')

    get items_ctrax_days_path(date: @date, location_id: @uptown.id, format: :csv)
    assert_equal 1, CSV.parse(response.body, headers: true).size
  end

  test 'items pages follow sales read access and reject bad input' do
    get items_ctrax_days_path(date: 'not-a-date')
    assert_redirected_to ctrax_days_path
    get items_ctrax_days_path(date: @date + 1)
    assert_response :success
    assert_select '.empty-state-title', 'No stored sales for this date'
    get items_ctrax_days_path(date: @date, location_id: 'missing')
    assert_response :not_found
    @user.update_permission_overrides!(%w[sales.read])
    get ctrax_day_path(@downtown_day)
    assert_response :success
    assert_select '#close-not-in-catalog a[href^="/stock_comparison"]', count: 0
    @user.update_permission_overrides!(%w[dashboard.read])
    get items_ctrax_days_path(date: @date)
    assert_response :redirect
  end
end
