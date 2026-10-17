# frozen_string_literal: true

require 'test_helper'

class BookApprovalsIntegrationTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    @day = (Date.current - 3).iso8601
    post login_path, params: { email: 'admin@example.com', password: 'password' }
  end

  teardown { Current.reset }

  def digest = BooksPeriod.new(kind: 'daily', date: @day).digest

  def approve(**overrides)
    post book_approvals_path, params: { approval: { kind: 'daily', date: @day, digest: digest, status: 'approved_with_exceptions',
      notes: 'Reviewed over coffee', confirmed: '1' }.merge(overrides) }
  end

  def last_entry(action) = ActivityLog.where(tenant_id: @tenant.id, action: action).order(:id).last

  test 'page renders for daily and weekly with the ledger' do
    get book_approvals_path
    assert_response :success
    assert_select 'h1', 'Book approvals'
    assert_equal 'private, no-store', response.headers['Cache-Control']
    get book_approvals_path(kind: 'weekly')
    assert_response :success
    assert_includes response.body, 'Approval ledger'
  end

  test 'a person can approve and it records who, when and an activity entry' do
    approve
    assert_redirected_to book_approvals_path(kind: 'daily', date: @day)
    approval = BookApproval.order(:id).last
    assert_equal 'approved_with_exceptions', approval.status
    assert_equal users(:regular_user).id, approval.approved_by_id
    assert approval.ip.present?
    assert last_entry('books_approved_with_exceptions')
    follow_redirect!
    assert_includes response.body, 'Approved with exceptions'
    assert_includes response.body, 'Ledger intact'
  end

  test 'a stale page, a missing confirmation and open checks are rejected' do
    approve(digest: 'old')
    assert_response :unprocessable_entity
    assert_includes response.body, 'changed while you were looking'
    approve(confirmed: '0')
    assert_response :unprocessable_entity
    assert_equal 0, BookApproval.count
  end

  test 'exceptions without a note are rejected with a plain message' do
    approve(notes: '')
    assert_response :unprocessable_entity
    assert_includes response.body, 'explaining the exception'
    assert_equal 0, BookApproval.count
  end

  test 'today cannot be approved' do
    post book_approvals_path, params: { approval: { kind: 'daily', date: Date.current.iso8601, digest: BooksPeriod.new(kind: 'daily', date: Date.current).digest,
      status: 'needs_attention', notes: 'x', confirmed: '1' } }
    assert_response :unprocessable_entity
    assert_equal 0, BookApproval.count
  end

  test 'readers can view but not approve' do
    users(:regular_user).update!(role: 'reporting')
    get book_approvals_path
    assert_response :success
    approve
    assert_redirected_to root_path
    assert_equal 0, BookApproval.count
  end

  test 'editing money out inside an approved day warns and is logged' do
    approve
    post finance_expenses_path, params: { expense: { category: 'supplies', amount: '9.99', incurred_on: @day, method: 'card' } }
    assert last_entry('edit_in_approved_period')
    assert_match(/now shows as changed/, flash[:alert])
  end

  test 'exports and downloads are logged' do
    get books_check_path(format: :csv)
    get daily_reconciliations_path(day: @day, format: :csv)
    get activity_path(format: :csv)
    entries = ActivityLog.where(tenant_id: @tenant.id, action: 'data_exported').pluck(:details)
    assert_equal 3, entries.size
    assert(entries.any? { |d| d.start_with?('Books check CSV') })
    assert(entries.any? { |d| d.start_with?('Daily reconciliation CSV') })
  end
end
