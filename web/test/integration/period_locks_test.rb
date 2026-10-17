# frozen_string_literal: true

require 'test_helper'

class PeriodLocksIntegrationTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    Finance::ChartOfAccounts.seed! # expenses post to the ledger, which needs the chart
    @month = Date.current.beginning_of_month << 2
    post login_path, params: { email: 'admin@example.com', password: 'password' }
  end

  teardown { Current.reset }

  def lock(**overrides)
    post period_locks_path, params: { period_lock: { kind: 'monthly', date: @month.iso8601, act: 'lock', confirmed: '1', reason: 'Checked at month end' }.merge(overrides) }
  end

  test 'page renders the focused period, calendar and ledger' do
    get period_locks_path(kind: 'monthly', date: @month.iso8601)
    assert_response :success
    assert_select 'h1', 'Period locks'
    assert_select '#lock-focus-title', PeriodLock.label('monthly', @month)
    assert_select 'ol.lock-grid', 3
    assert_includes response.body, 'Lock ledger'
  end

  test 'locking records who, retains an archive and blocks edits inside the month' do
    lock
    assert_redirected_to period_locks_path(kind: 'monthly', date: @month.iso8601)
    event = PeriodLock.order(:id).last
    assert event.lock?
    assert_equal @month.end_of_month, event.period_to
    assert ReconciliationDocument.exists?(id: event.archive_document_id, kind: 'period_archive')
    assert ActivityLog.where(action: 'period_locked').exists?
    assert PeriodLock.verify_chain[:ok]

    assert_no_difference 'Finance::Expense.count' do
      post finance_expenses_path, params: { expense: { payee: 'Late', category: 'supplies', amount: '9.99', incurred_on: @month + 3, method: 'card' } }
    end
    assert_response :unprocessable_entity
    assert_includes response.body, 'is locked'

    post finance_expenses_path, params: { expense: { payee: 'Today', category: 'supplies', amount: '9.99', incurred_on: Date.current, method: 'card' } }
    assert_redirected_to finance_expenses_path
  end

  test 'records cannot be moved out of or removed from a locked month' do
    expense = Finance::Expense.create!(payee: 'Before lock', category: 'other', amount_cents: 500, incurred_on: @month + 1, method: 'card')
    lock
    assert_not expense.reload.update(incurred_on: Date.current)
    assert_match(/is locked/, expense.errors.full_messages.to_sentence)
    delete finance_expense_path(expense)
    assert_redirected_to finance_expenses_path
    assert_match(/is locked/, flash[:alert])
    assert_not expense.reload.discarded?
  end

  test 'approvals and reviews inside a locked month are refused' do
    lock
    day = @month + 4
    period = BooksPeriod.new(kind: 'daily', date: day)
    assert_raises(ActiveRecord::RecordInvalid) do
      BookApproval.record!(period: period, status: 'approved', notes: nil, user: users(:regular_user))
    end
    assert_raises(ActiveRecord::RecordInvalid) do
      DailyReconciliationReview.create!(day: day, report_digest: 'x', status: 'reviewed', notes: 'late')
    end
  end

  test 'unlocking needs a reason and settings access, and is recorded' do
    lock
    post period_locks_path, params: { period_lock: { kind: 'monthly', date: @month.iso8601, act: 'unlock', confirmed: '1', reason: '' } }
    assert_response :unprocessable_entity
    assert_includes response.body, 'Explain why'
    post period_locks_path, params: { period_lock: { kind: 'monthly', date: @month.iso8601, act: 'unlock', confirmed: '1', reason: 'Late supplier invoice' } }
    assert_redirected_to period_locks_path(kind: 'monthly', date: @month.iso8601)
    assert_not PeriodLock.locked?(@month + 3)
    assert_equal %w[lock unlock], PeriodLock.chronological.pluck(:action)
    assert PeriodLock.verify_chain[:ok]
  end

  test 'a period that has not finished cannot be locked and confirmation is required' do
    post period_locks_path, params: { period_lock: { kind: 'monthly', date: Date.current.iso8601, act: 'lock', confirmed: '1', reason: 'x' } }
    assert_response :unprocessable_entity
    lock(confirmed: '0')
    assert_response :unprocessable_entity
    assert_equal 0, PeriodLock.count
  end

  test 'changes after a lock are detected' do
    lock
    event = PeriodLock.order(:id).last
    assert event.still_matches?
    Finance::Expense.unscoped.insert_all([{ tenant_id: @tenant.id, payee: 'Backdoor', category: 'other', amount_cents: 100,
      incurred_on: @month + 2, method: 'card', created_at: Time.current, updated_at: Time.current }])
    assert_not event.still_matches?
    assert_includes PeriodSnapshot.new(from: event.period_from, to: event.period_to).changed_sections(event.summary), 'Expenses'
  end
end
