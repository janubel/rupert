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

  test 'forecast keeps exact cents one currency explicit inputs and immutable retained scenarios' do
    baseline = DailyMoneyReconciliation.new(day: @day).digest
    assert_no_enqueued_jobs do
      assert_no_difference ['ReconciliationDocument.count', 'ActionMailer::Base.deliveries.size'] do
        post cash_forecast_path, params: { intent: 'preview', forecast: @forecast_values }
      end
    end
    assert_response :success
    assert_includes response.body, 'Week 3'
    assert_select '#forecast-results', text: /20\.01/
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
