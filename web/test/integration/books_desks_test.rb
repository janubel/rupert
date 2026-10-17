# frozen_string_literal: true

require 'test_helper'

class BooksDesksIntegrationTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    post login_path, params: { email: 'admin@example.com', password: 'password' }
  end

  teardown { Current.reset }

  test 'desk shows the next step, the week, period ends and grouped navigation' do
    get books_desk_path
    assert_response :success
    assert_equal 'private, no-store', response.headers['Cache-Control']
    assert_select 'h1', 'Close & review'
    assert_select '#desk-next-title'
    assert_select '#reconciliation-findings'
    assert_includes response.body, 'Bank deposit matching remains incomplete.'
    assert_select '#reconciliation-findings', text: /Checked (?!Unknown time)/
    assert_select '#desk-focus-week', text: /Last week/
    assert_select 'ol.desk-steps', minimum: 7
    assert_select '#desk-period-end'
    assert_select 'article[aria-labelledby=close-monthly]'
    assert_select 'article[aria-labelledby=close-yearly]'
    assert_select 'turbo-frame#books-desk-checks[src=?]', checks_books_desk_path
    assert_select 'nav[aria-label="Bookkeeping workspace"] a[aria-current=page]', text: 'Close & review'
    assert_select 'nav[aria-label="Bookkeeping workspace"] .workspace-nav-group', text: 'Reconcile & close'
  end

  test 'an earlier week can be chosen and a future week falls back to last week' do
    get books_desk_path(week: (Date.current - 30).iso8601)
    assert_response :success
    assert_select '#desk-focus-week', text: /Earlier week/
    get books_desk_path(week: (Date.current + 30).iso8601)
    assert_select '#desk-focus-week', text: /Last week/
    get books_desk_path(week: 'not-a-date')
    assert_redirected_to books_desk_path
  end

  test 'an approved week counts its days as approved' do
    monday = Date.current.beginning_of_week - 7
    period = BooksPeriod.new(kind: 'weekly', date: monday)
    BookApproval.record!(period: period, status: 'approved_with_exceptions', notes: 'Checked', user: users(:regular_user))
    desk = BooksDesk.new
    assert(desk.focus_days.all? { |day| day.stages.last.state == :exception })
  end

  test 'housekeeping frame renders the books check summary' do
    get checks_books_desk_path
    assert_response :success
    assert_select 'turbo-frame#books-desk-checks'
    assert_includes response.body, 'checks'
  end

  test 'people without report access cannot open the desk' do
    users(:regular_user).update!(role: 'employee')
    get books_desk_path
    assert_response :redirect
  end
  test 'finance screens share one complete header and identify their own page' do
    [books_desk_path, period_locks_path, book_approvals_path, bank_statements_path,
     business_snapshot_path, books_check_path, finance_accounts_path, finance_expenses_path,
     finance_vendor_payments_path, finance_chart_of_accounts_path, ledger_index_path].each do |path|
      get path
      assert_response :success
      assert_select 'nav[aria-label="Bookkeeping workspace"]', count: 1
      assert_select 'nav[aria-label="Bookkeeping workspace"] a[aria-current="page"]', count: 1
      assert_select 'nav[aria-label="Bookkeeping workspace"] .workspace-nav-group', text: 'Reconcile & close'
      assert_select 'nav[aria-label="Bookkeeping workspace"] .workspace-nav-group', text: 'Records'
      assert_select 'nav[aria-label="Bookkeeping workspace"] .workspace-nav-group', text: 'Reports & control'
      assert_select 'nav[aria-label="Module areas"] a.nav-pill-active', text: 'Bookkeeping'
    end
  end
end
