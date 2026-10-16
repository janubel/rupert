# frozen_string_literal: true

require 'test_helper'

class FinancialCloseLifecycleTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = Tenant.create!(name: 'Close lifecycle', subdomain: 'close-lifecycle')
    Current.tenant = @tenant
    @user = User.create!(tenant: @tenant, email: 'close-reviewer@example.com', role: 'admin', password: 'password123')
    post login_path, params: { email: @user.email, password: 'password123' }
    Current.tenant = @tenant
    @day = '2026-10-14'
    @original = ReconciliationEvidence.retain!(bytes: 'synthetic statement', filename: 'statement.txt', source: 'bank', kind: 'bank_statement', from: @day, to: @day)
    @forecast_values = { as_of: @day, currency: 'CAD', horizon: '4', opening: '100.01', reserve: '50', basis: 'assumption', notes: 'Synthetic cash plan, bank timing entered manually.',
      weeks: 4.times.to_h { |i| [i.to_s, { receipts: '10', payments: '30' }] } }
  end
  teardown { Current.reset }

  def record_review
    DailyReconciliationReview.create!(day: @day, report_digest: DailyMoneyReconciliation.new(day: @day).digest, status: 'reviewed', notes: 'Original inspected; manual bank checks documented.', reviewed_by: @user)
  end

  def close_values
    { day: @day, workflow_digest: FinancialCloseWorkflow.new(day: @day).digest, disposition: 'complete', notes: 'Original and policy checks completed by reviewer.' }
      .merge(FinancialCloseWorkflow::CHECKS.keys.to_h { |key| [key, '1'] })
  end

  test 'close requires current review and checklist then retains stable replayable evidence without messaging' do
    get financial_close_path(day: @day)
    assert_response :success
    assert_select 'h1', 'Financial close'
    assert_select 'div[aria-label="Financial close lifecycle"] section', count: 6
    assert_includes response.body, 'Review not recorded'
    assert_select '[aria-label="Checks needing action"]', text: /Required for any package/
    assert_select 'input[value="Verify originals & retain close package"][disabled]'
    assert_select 'a[href=?]', financial_close_path(day: '2026-10-13'), text: 'Previous day'
    assert_select 'a[href=?]', financial_close_path(day: '2026-10-15'), text: 'Next day'
    assert_no_difference 'ReconciliationDocument.count' do
      post financial_close_path, params: { close: close_values }
    end
    assert_response :unprocessable_entity
    record_review
    assert_no_difference 'ReconciliationDocument.count' do
      post financial_close_path, params: { close: close_values.merge(originals_checked: '0') }
    end
    assert_response :unprocessable_entity
    values = close_values
    assert_no_enqueued_jobs do
      assert_no_difference 'ActionMailer::Base.deliveries.size' do
        assert_difference 'ReconciliationDocument.count', 2 do
          post financial_close_path, params: { close: values }
        end
      end
    end
    assert_response :redirect
    package = ReconciliationDocument.where(kind: 'close_package').last
    data = JSON.parse(package.original_bytes)
    assert_equal @original.sha256, data['originals'].first['sha256']
    assert_equal 'complete', data['disposition']
    assert_equal @user.id, data['reviewer_id']
    assert_equal values[:workflow_digest], FinancialCloseWorkflow.new(day: @day).digest
    assert FinancialCloseWorkflow.new(day: @day).review_current?
    assert_no_difference 'ReconciliationDocument.count' do
      post financial_close_path, params: { close: values }
    end
    follow_redirect!
    assert_includes response.body, 'Matches current evidence and follow-up progress'
    get reconciliation_documents_path(category: 'archives', source: 'rupert')
    assert_includes response.body, 'Financial close package'
  end

  test 'changed follow-ups reject stale close and unresolved work requires documented exceptions' do
    record_review
    stale = close_values
    item = ReconciliationFollowUp.create!(category: 'missing_report', source: 'bank', document_kind: 'bank_statement', period_from: @day, period_to: @day,
      title: 'Additional statement needed', notes: 'Check the second account.', due_on: @day, submission_key: SecureRandom.uuid)
    assert_no_difference 'ReconciliationDocument.count' do
      post financial_close_path, params: { close: stale }
      assert_response :unprocessable_entity
      assert_includes response.body, 'follow-up progress changed'
      post financial_close_path, params: { close: close_values }
      assert_response :unprocessable_entity
      assert_includes response.body, 'Outstanding checks remain'
    end
    post financial_close_path, params: { close: close_values.merge(disposition: 'with_exceptions', notes: 'Second bank statement outstanding; reviewer owns tomorrow check.') }
    assert_response :redirect
    data = JSON.parse(ReconciliationDocument.where(kind: 'close_package').last.original_bytes)
    assert_equal 1, data['issues']['open_follow_ups']
    assert_equal item.id, data['follow_ups'].first['id']
    assert_equal 'open', item.reload.status
    get financial_close_path(day: @day)
    assert_select '[aria-label="Priority follow-ups blocking close"]', text: /Additional statement needed/
    assert_select 'option[value="complete"][disabled]'
    assert_includes response.body, 'You can retain a package with documented exceptions'
    item.update!(notes: 'New next step changes package currency, not report totals.', due_on: '2026-10-16')
    get financial_close_path(day: @day)
    assert_includes response.body, 'Evidence or follow-up progress changed since this version'
  end

  test 'failed original verification blocks the package and preserves the closing explanation' do
    record_review
    values = close_values
    @original.update_column(:content_base64, Base64.strict_encode64('different original bytes'))
    assert_no_difference 'ReconciliationDocument.count' do
      post financial_close_path, params: { close: values }
    end
    assert_response :unprocessable_entity
    assert_includes response.body, 'failed verification'
    assert_select 'textarea[name="close[notes]"]', values[:notes]
  end

  test 'missing control actions pin the exact pool and reuse its existing overdue request' do
    travel_to Time.zone.parse('2026-10-16 12:00') do
      order = Core::Order.create!(source: 'square', source_order_id: 'close-blocker-order', currency: 'USD', occurred_at: Time.zone.parse("#{@day} 12:00"), gross_cents: 1000, tax_cents: 0)
      order.mark_paid!
      order.payments.create!(method: 'card', amount_cents: 1000, paid_at: order.occurred_at)
      item = ReconciliationFollowUp.create!(category: 'missing_report', source: 'square', currency: 'USD', document_kind: 'register_control', period_from: @day, period_to: @day,
        title: 'Square original needed', notes: 'Retain the exact source report.', due_on: @day, submission_key: SecureRandom.uuid)
      workflow = FinancialCloseWorkflow.new(day: @day)
      row = workflow.attention.missing_controls.first
      assert_no_enqueued_jobs do
        assert_no_difference ['ReconciliationFollowUp.count', 'ReconciliationFollowUpEvent.count', 'ActionMailer::Base.deliveries.size'] do
          get financial_close_path(day: @day)
        end
      end
      assert_select '[aria-label="Missing reports blocking close"]' do
        assert_select 'a[href=?]', daily_reconciliations_path(day: @day, control_for: workflow.attention.control_key(row), anchor: 'upload-document'), text: 'Add this control'
        assert_select 'a[href=?]', reconciliation_follow_up_path(item, close_day: @day, anchor: 'record-progress'), text: "Overdue request ##{item.id}"
        assert_select 'a', text: 'Track this missing report', count: 0
      end
      assert_select '#close-follow-ups a[href=?]', reconciliation_follow_up_path(item, close_day: @day, anchor: 'record-progress'), text: 'Record progress'
      assert_select '#close-follow-ups a[href=?]', daily_reconciliations_path(request: item.id, close_day: @day, anchor: 'upload-document'), text: 'Add original'
      item.update!(due_on: Date.current + 1, notes: 'Check the original tomorrow.')
      get cash_forecast_path(day: @day)
      assert_select '[aria-label="Next close action for 2026-10-14"]' do
        assert_select '[aria-label="Missing register report scope"]', text: /Square · USD/
        assert_select 'a[href=?]', daily_reconciliations_path(day: @day, control_for: workflow.attention.control_key(row), anchor: 'upload-document'), text: 'Add this control'
        assert_select 'a[href=?]', reconciliation_follow_up_path(item, close_day: @day, anchor: 'record-progress'), text: "Open request ##{item.id}"
        assert_select 'a', text: 'Track this missing report', count: 0
      end
      @user.update!(role: 'reporting')
      get financial_close_path(day: @day)
      assert_select 'a', text: 'Add this control', count: 0
      assert_select 'a[href=?]', reconciliation_follow_up_path(item, close_day: @day), text: "Open request ##{item.id}"
      get cash_forecast_path(day: @day)
      assert_select '[aria-label="Next close action for 2026-10-14"] a', text: 'Add this control', count: 0
    end
  end

  test 'forecast keeps exact cents one currency explicit inputs and immutable retained scenarios' do
    baseline = DailyMoneyReconciliation.new(day: @day).digest
    assert_no_enqueued_jobs do
      assert_no_difference ['ReconciliationDocument.count', 'ActionMailer::Base.deliveries.size'] do
        post cash_forecast_path, params: { intent: 'preview', forecast: @forecast_values }
      end
    end
    assert_response :success
    assert_includes response.body, 'Week 3'
    assert_select '[aria-label="Cash shortfall action"]', text: /CAD 9\.99 below your reserve/
    assert_select 'a[href="#cash-week-3"]', text: 'Review week 3 cash plan'
    assert_select '#forecast-results', text: /20\.01/
    assert_select '[aria-label="Forecast baseline close status"]', text: /Review not recorded/
    assert_select 'a[href=?]', overview_reconciliation_follow_ups_path(ending_on: @day, anchor: 'business-days'), text: 'Compare close dates'
    assert_select '[data-cash-forecast-form-baseline-date-value=?]', @day
    assert_select 'input[name="forecast[weeks][0][receipts]"][value="10"]'
    assert_difference 'ReconciliationDocument.count', 1 do
      post cash_forecast_path, params: { intent: 'retain', forecast: @forecast_values.merge(baseline_digest: baseline) }
    end
    assert_response :success
    doc = ReconciliationDocument.where(kind: 'cash_forecast').last
    data = JSON.parse(doc.original_bytes)
    assert_equal 'CAD', data['currency']
    assert_equal 2001, data['rows'].last['closing_cents']
    assert_equal baseline, DailyMoneyReconciliation.new(day: @day).digest
    assert_no_difference 'ReconciliationDocument.count' do
      post cash_forecast_path, params: { intent: 'retain', forecast: @forecast_values.merge(baseline_digest: baseline) }
    end
    post cash_forecast_path, params: { intent: 'csv', forecast: @forecast_values }
    assert_response :success
    assert_includes response.headers['Content-Type'], 'text/csv'
    assert_includes response.body, '2001'
    assert_equal 'no-store', response.headers['Cache-Control']
    post cash_forecast_path, params: { intent: 'preview', forecast: @forecast_values.deep_merge(weeks: { '2' => { payments: '' } }) }
    assert_response :unprocessable_entity
    assert_includes response.body, 'Week 3 payments: enter an explicit amount'
    assert_select 'textarea[name="forecast[notes]"]', @forecast_values[:notes]
    post cash_forecast_path, params: { intent: 'retain', forecast: @forecast_values.merge(baseline_digest: 'stale') }
    assert_response :unprocessable_entity
    assert_includes response.body, 'baseline report changed'
  end

  test 'across dates exposes close and overdue actions with the selected date for report readers' do
    travel_to Time.zone.parse('2026-10-16 12:00') do
      item = ReconciliationFollowUp.create!(category: 'missing_report', source: 'bank', document_kind: 'bank_statement', period_from: @day, period_to: @day,
        title: 'Overdue original for close', notes: 'Local next step only.', due_on: @day, submission_key: SecureRandom.uuid)
      @user.update!(role: 'reporting')
      assert_no_enqueued_jobs do
        assert_no_difference ['ReconciliationDocument.count', 'ReconciliationFollowUpEvent.count', 'ActionMailer::Base.deliveries.size'] do
          get overview_reconciliation_follow_ups_path(ending_on: @day)
        end
      end
      assert_response :success
      get overview_reconciliation_follow_ups_path(ending_on: @day, focus: 'overdue')
      assert_select 'article[aria-label^="Business date"]', count: 1
      assert_select '[aria-label="Next close action for 2026-10-14"]' do
        assert_select 'a[href=?]', reconciliation_follow_up_path(item, close_day: @day), text: 'Open this follow-up'
        assert_select 'a', text: 'Record progress on this follow-up', count: 0
      end
      assert_select 'a[aria-current="page"]', text: 'Overdue work · 1'
      assert_select '[aria-label="Close status for 2026-10-14"]' do
        assert_select 'a[href=?]', financial_close_path(day: @day), text: 'Open financial close'
        assert_select 'a[href=?]', cash_forecast_path(day: @day), text: 'Plan cash from this date'
        assert_select 'a[href=?]', reconciliation_follow_ups_path(day: @day, status: 'overdue'), text: 'Overdue follow-ups · 1'
      end
      get cash_forecast_path(day: @day)
      assert_select '[aria-label="Forecast baseline close status"] a[href=?]', reconciliation_follow_ups_path(day: @day, status: 'overdue'), text: 'Work 1 overdue follow-up'
      assert_select '[aria-label="Forecast baseline close status"] a[href=?]', reconciliation_follow_up_path(item, close_day: @day), text: 'Open this follow-up'
      get overview_reconciliation_follow_ups_path(ending_on: @day, focus: 'changed')
      assert_select 'article[aria-label^="Business date"]', count: 0
      assert_includes response.body, 'No dates match this focus'
      @user.update!(role: 'admin')
      get overview_reconciliation_follow_ups_path(ending_on: @day, focus: 'overdue')
      assert_select '[aria-label="Next close action for 2026-10-14"] a[href=?]', reconciliation_follow_up_path(item, close_day: @day, anchor: 'record-progress'), text: 'Record progress on this follow-up'
      get overview_reconciliation_follow_ups_path(ending_on: @day, focus: 'invalid')
      assert_select 'article[aria-label^="Business date"]', count: 7
    end
  end

  test 'readers can preview but cannot retain and employees and foreign tenants cannot reach financial evidence' do
    @user.update!(role: 'reporting')
    get financial_close_path(day: @day)
    assert_response :success
    assert_select 'input[type="submit"][value="Verify originals & retain close package"]', count: 0
    post cash_forecast_path, params: { intent: 'preview', forecast: @forecast_values }
    assert_response :success
    assert_select 'button[value="retain"]', count: 0
    assert_no_difference 'ReconciliationDocument.count' do
      post financial_close_path, params: { close: close_values }
      assert_response :redirect
      post cash_forecast_path, params: { intent: 'retain', forecast: @forecast_values }
      assert_response :redirect
    end
    other = Tenant.create!(name: 'Foreign close', subdomain: 'foreign-close')
    @user.update!(tenant: other)
    get financial_close_path(day: @day)
    refute_includes response.body, @original.filename
    get document_daily_reconciliation_path(@original)
    assert_response :not_found
    @user.update!(role: 'employee')
    [financial_close_path, cash_forecast_path].each do |path|
      get path
      assert_response :redirect
    end
  end
end
