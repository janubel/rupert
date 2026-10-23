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

  def assert_blank_field(id)
    assert_select("##{id}") { |field| assert_equal '', field.first['value'].to_s }
  end

  def record_review
    DailyReconciliationReview.create!(day: @day, report_digest: DailyMoneyReconciliation.new(day: @day).digest, status: 'reviewed', notes: 'Original inspected; manual bank checks documented.', reviewed_by: @user)
  end

  def close_values
    { day: @day, workflow_digest: FinancialCloseWorkflow.new(day: @day).digest, disposition: 'complete', notes: 'Original and policy checks completed by reviewer.' }
      .merge(FinancialCloseWorkflow::CHECKS.keys.to_h { |key| [key, '1'] })
  end

  test 'locally-created sales are self-confirmed; imported sources without an import still flag' do
    pos = Core::Order.create!(source: 'rupert_pos', source_order_id: SecureRandom.uuid,
      occurred_at: Time.zone.parse("#{@day} 12:00"), gross_cents: 2500, tax_cents: 0, currency: 'USD')
    pos.mark_paid!
    assert_includes FinancialCloseWorkflow.new(day: @day).report.register.rows.map { |r| r[:source] }, 'rupert_pos'
    assert_equal 0, FinancialCloseWorkflow.new(day: @day).issues[:unconfirmed_imports]

    square = Core::Order.create!(source: 'square', source_order_id: SecureRandom.uuid,
      occurred_at: Time.zone.parse("#{@day} 12:00"), gross_cents: 1000, tax_cents: 0, currency: 'USD')
    square.mark_paid!
    # square has an import pathway; with no SyncRun it remains an unconfirmed import
    assert_equal 1, FinancialCloseWorkflow.new(day: @day).issues[:unconfirmed_imports]
  end

  test 'close requires current review and checklist then retains stable replayable evidence without messaging' do
    get financial_close_path(day: @day)
    assert_response :success
    assert_select 'h1', 'Day close'
    assert_select 'div[aria-label="Day close lifecycle"] section', count: 6
    assert_includes response.body, 'Review not recorded'
    assert_select '[aria-label="Checks needing action"]', text: /Required for any package/
    assert_select 'input[value="Verify originals & retain close package"][disabled]'
    assert_select 'a[href=?][aria-label="Previous day"]', financial_close_path(day: '2026-10-13')
    assert_select 'a[href=?][aria-label="Next day"]', financial_close_path(day: '2026-10-15')
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

  test 'missing report search preserves server-derived control scope and reuses a request created after the prompt' do
    location = Location.create!(source: 'square', externalId: 'scope-store', name: 'Scope store')
    order = Core::Order.create!(source: 'square', source_order_id: 'control-search-order', location_id: location.id, currency: 'EUR', occurred_at: Time.zone.parse("#{@day} 12:00"), gross_cents: 1000, tax_cents: 0)
    order.mark_paid!
    workflow = FinancialCloseWorkflow.new(day: @day)
    row = workflow.attention.missing_controls.find { |item| item[:location_id] == location.id }
    key = workflow.attention.control_key(row)
    search = { source: 'square', from: @day, to: @day, close_day: @day, control_for: key, q: 'absent', currency: 'USD', location_id: 'wrong-location' }
    assert_no_enqueued_jobs do
      assert_no_difference ['ReconciliationFollowUp.count', 'ReconciliationFollowUpEvent.count', 'ActionMailer::Base.deliveries.size'] do
        get reconciliation_documents_path(search)
        assert_response :success
        assert_select '[aria-label="Missing register report search"]', text: /Square · EUR · Oct 14, 2026/
        assert_select '[aria-label="Missing register report search"]', text: /Scope store/
        assert_select 'form input[name="control_for"][value=?]', key
        tracking = css_select('[aria-label="Missing register report search"] a').find { |link| link.text == 'Track this missing report' }['href']
        get tracking
        assert_select 'select[name="follow_up[document_kind]"] option[selected][value="register_control"]'
        assert_select 'input[name="follow_up[currency]"][value="EUR"]'
        assert_select 'select[name="follow_up[location_id]"] option[selected][value=?]', location.id
        assert_select 'input[name="follow_up[period_from]"][value=?]', @day
        assert_select 'input[name="close_day"][value=?]', @day
        get reconciliation_documents_path(search.merge(from: '2026-10-15', to: '2026-10-15'))
        assert_select '[aria-label="Missing register report search"]', text: /Square · EUR · Oct 14, 2026/
        assert_select 'input[name="close_day"][value=?]', @day
        get overview_reconciliation_follow_ups_path(ending_on: @day)
        assert_select '#report-gaps a[href=?]', reconciliation_documents_path(source: 'square', from: @day, to: @day, close_day: @day, control_for: key), text: 'Find retained reports'
      end
    end
    item = ReconciliationFollowUp.create!(category: 'missing_report', source: 'square', document_kind: 'register_control', currency: 'EUR', location_id: location.id,
      period_from: @day, period_to: @day, due_on: Date.current - 1, title: 'Existing scoped request', notes: 'Original needed.', submission_key: SecureRandom.uuid)
    get reconciliation_documents_path(search)
    assert_select '[aria-label="Report request being resolved"]', text: /Existing scoped request/
    assert_select '[aria-label="Missing register report search"]', count: 0
    assert_select 'a', text: 'Track this missing report', count: 0
    assert_select 'input[name="follow_up"][value=?]', item.id.to_s
    assert_select 'input[name="control_for"]', count: 0
    @user.update!(role: 'reporting')
    get reconciliation_documents_path(search)
    assert_select 'a', text: 'Add missing original', count: 0
  end

  test 'stale invalid and foreign missing-control searches cannot create a scoped request' do
    order = Core::Order.create!(source: 'square', source_order_id: 'stale-control-search', currency: 'USD', occurred_at: Time.zone.parse("#{@day} 12:00"), gross_cents: 1000, tax_cents: 0)
    order.mark_paid!
    row = FinancialCloseWorkflow.new(day: @day).attention.missing_controls.first
    key = ReconciliationAttention.control_key(row)
    search = { from: @day, to: @day, close_day: @day, control_for: key, q: 'absent' }
    ['invalid', 'f' * 64].each do |value|
      get reconciliation_documents_path(search.merge(control_for: value))
      assert_select '[aria-label="Missing register report search"]', text: /Review the latest close checks/
      assert_select 'a', text: /Track.*missing report/, count: 0
    end
    @user.update!(role: 'reporting')
    get reconciliation_documents_path(search)
    assert_select '[aria-label="Missing register report search"]', text: /Square · USD/
    assert_select 'a', text: 'Add this control', count: 0
    assert_select 'a', text: /Track.*missing report/, count: 0
    @user.update!(role: 'admin')
    ReconciliationEvidence.retain!(bytes: 'Synthetic current control', filename: 'current-control.txt', source: 'square', kind: 'register_control', from: @day, to: @day, metadata: { 'currency' => 'USD', 'cash' => 0 })
    get reconciliation_documents_path(search)
    assert_select '[aria-label="Missing register report search"]', text: /no longer available/
    assert_select 'a', text: /Track.*missing report/, count: 0
    other = Tenant.create!(name: 'Foreign scope', subdomain: 'foreign-control-scope')
    @user.update!(tenant: other)
    get reconciliation_documents_path(search)
    assert_select '[aria-label="Missing register report search"]', text: /Review the latest close checks/
    assert_select 'a', text: /Track.*missing report/, count: 0
  end

  test 'cash checklist requires base entries, allows blank weeks and ties amount errors to their field for readers' do
    @user.update!(role: 'reporting')
    get cash_forecast_path(day: @day)
    assert_response :success
    assert_select '[aria-label="Cash plan input checklist"]'
    assert_select '#cash-plan-checklist button[type="button"][data-action="cash-forecast-form#jumpMissing"]', text: 'Review next missing entry'
    assert_select '[data-cash-forecast-form-target~="entry"]:not([disabled])', count: 4
    assert_select '[data-cash-forecast-form-target~="amount"]:not([disabled]):not([required])', count: 16
    assert_select 'label.sr-only[for="forecast_weeks_7_payments"]', text: 'Week 8 cash payments'
    assert_select '#cash-week-table input.text-right.tabular-nums', count: 26
    assert_select '[role="toolbar"][aria-label="Weekly amount fill helpers"] button[data-action="cash-forecast-form#fillDown"]', count: 2
    values = @forecast_values.deep_dup
    values[:weeks]['1'][:payments] = ''
    values[:weeks]['2'][:receipts] = 'abc'
    values[:weeks]['3'][:receipts] = '77.00'
    assert_no_enqueued_jobs do
      assert_no_difference ['ReconciliationDocument.count', 'ActionMailer::Base.deliveries.size'] do
        post cash_forecast_path, params: { intent: 'preview', forecast: values }
      end
    end
    assert_response :unprocessable_entity
    assert_select '#cash-forecast-error[role="alert"]', text: /Week 3 bank receipts/
    assert_select '#cash-forecast-error a[href="#forecast_weeks_2_receipts"]', text: 'Go to this entry'
    assert_select '#forecast_weeks_2_receipts[aria-invalid="true"][aria-describedby="cash-forecast-error"][value="abc"]'
    assert_select '#forecast_weeks_1_receipts[aria-invalid]', count: 0
    assert_select '[data-cash-forecast-form-target~="entry"]:not([disabled])', count: 4
    assert_select '#forecast_weeks_3_receipts[value="77.00"][data-entry-label="Week 4 bank receipts"]'
    assert_select '#forecast_weeks_4_receipts[disabled]'
    assert_select 'button', text: 'Retain scenario version', count: 0
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
    assert_select '#forecast-results [data-cash-forecast-form-target="changed"][hidden]', text: /previous inputs/
    assert_select '#forecast-results a[href="#cash-plan-checklist"]', text: 'Review cash plan entries'
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
    post cash_forecast_path, params: { intent: 'preview', forecast: @forecast_values.merge(opening: '') }
    assert_response :unprocessable_entity
    assert_includes response.body, 'Opening cash: enter an explicit amount'
    assert_select 'textarea[name="forecast[notes]"]', @forecast_values[:notes]
    post cash_forecast_path, params: { intent: 'retain', forecast: @forecast_values.merge(baseline_digest: 'stale') }
    assert_response :unprocessable_entity
    assert_includes response.body, 'baseline report changed'
  end

  test 'blank weeks count as zero only after the exact blank entries are confirmed and the confirmation is retained' do
    baseline = DailyMoneyReconciliation.new(day: @day).digest
    blank = @forecast_values.deep_merge(weeks: { '1' => { payments: '' }, '3' => { receipts: ' ' } }, baseline_digest: baseline)
    post cash_forecast_path, params: { intent: 'preview', forecast: blank }
    assert_response :success
    assert_select '[aria-label="Blank entries counted as zero"]', text: /2 blank weekly entries counted as 0/
    assert_select '#forecast-results tfoot', text: /Total · 4 weeks\s*100\.01\s*30\.00\s*90\.00\s*−60\.00\s*40\.01/
    assert_select '#forecast-results table.tabular-nums td', text: /\(blank\)/, count: 2
    assert_select '#cash-zero-confirmation h2', text: '2 blank weekly entries will be saved as 0'
    assert_select '#cash-zero-confirmation li a[href="#forecast_weeks_1_payments"]', text: 'Week 2 · Oct 22 – Oct 28 · payments'
    assert_select '#cash-zero-confirmation li a[href="#forecast_weeks_3_receipts"]', text: /Week 4 .* bank receipts/
    assert_select 'input[type="checkbox"][name="forecast[zero_confirmation]"][value="2:payments,4:receipts"][data-review-only]:not([checked])'
    %w[retain csv].each do |intent|
      [nil, '2:payments', '2:payments,4:receipts,1:receipts'].each do |confirmation|
        assert_no_difference 'ReconciliationDocument.count' do
          post cash_forecast_path, params: { intent: intent, forecast: blank.merge(zero_confirmation: confirmation) }
        end
        assert_response :unprocessable_entity
        assert_select '#cash-forecast-error a[href="#cash-zero-confirmation"]'
        assert_select '#forecast_zero_confirmation[aria-invalid="true"][aria-describedby="cash-zero-error"]'
        assert_select '#cash-zero-error', text: 'Confirm the 2 blank weekly entries listed below will be saved as 0, or enter amounts for them.'
      end
    end
    post cash_forecast_path, params: { intent: 'csv', forecast: blank.merge(zero_confirmation: '2:payments,4:receipts') }
    assert_includes response.body, 'Blank entries confirmed as 0,Week 2 payments; Week 4 bank receipts'
    assert_difference 'ReconciliationDocument.count', 1 do
      post cash_forecast_path, params: { intent: 'retain', forecast: blank.merge(zero_confirmation: '2:payments,4:receipts') }
    end
    doc = ReconciliationDocument.where(kind: 'cash_forecast').last
    expected = [{ 'week' => 2, 'field' => 'payments' }, { 'week' => 4, 'field' => 'receipts' }]
    assert_equal expected, doc.metadata['blank_entries_confirmed_as_zero']
    assert_equal expected, JSON.parse(doc.original_bytes)['blank_entries_confirmed_as_zero']
    assert_equal [1000, 1000, 1000, 0], JSON.parse(doc.original_bytes)['rows'].map { |row| row['receipts_cents'] }
    post cash_forecast_path, params: { intent: 'retain', forecast: @forecast_values.merge(baseline_digest: baseline) }
    assert_equal [], ReconciliationDocument.where(kind: 'cash_forecast').last.metadata['blank_entries_confirmed_as_zero']
  end

  test 'cash forecast prefills from the latest retained scenario in its currency, shifting whole weeks only' do
    baseline = DailyMoneyReconciliation.new(day: @day).digest
    weeks = { '0' => { receipts: '1', payments: '2' }, '1' => { receipts: '3', payments: '' }, '2' => { receipts: '5', payments: '6' }, '3' => { receipts: '7', payments: '8' } }
    post cash_forecast_path, params: { intent: 'retain', forecast: @forecast_values.merge(weeks: weeks, baseline_digest: baseline, zero_confirmation: '2:payments') }
    source = ReconciliationDocument.where(kind: 'cash_forecast').last
    get cash_forecast_path(day: @day)
    assert_select '#cash-prefill', count: 0
    assert_select 'a[href=?]', cash_forecast_path(day: @day, currency: 'CAD'), text: 'Start from the latest CAD scenario'
    get cash_forecast_path(day: '2026-10-21', currency: 'cad')
    assert_select '#cash-prefill h2', text: "Started from retained scenario ##{source.id}"
    assert_select '#cash-prefill', text: /moved 1 week earlier.*Week 4 had no earlier amount.*Opening cash is not carried/m
    assert_select 'input[name="forecast[prefilled_from]"][value=?]', source.id.to_s
    assert_select '#forecast_currency[value="CAD"]'
    assert_select '#forecast_horizon option[selected][value="4"]'
    assert_blank_field 'forecast_opening'
    assert_select '#forecast_reserve[value="50.00"]'
    assert_select 'textarea[name="forecast[notes]"]', @forecast_values[:notes]
    assert_select '#forecast_weeks_0_receipts[value="3.00"]'
    assert_blank_field 'forecast_weeks_0_payments'
    assert_select '#forecast_weeks_2_payments[value="8.00"]'
    assert_blank_field 'forecast_weeks_3_receipts'
    assert_select '#cash-prefill a[href=?]', cash_forecast_path(day: '2026-10-21', currency: 'CAD', prefill: 'none'), text: 'Clear prefill and start blank'
    get cash_forecast_path(day: @day, currency: 'CAD')
    assert_select '#cash-prefill', text: /Same close date/
    assert_select '#forecast_opening[value="100.01"]'
    assert_select '#forecast_weeks_1_receipts[value="3.00"]'
    get cash_forecast_path(day: '2026-10-17', currency: 'CAD')
    assert_select '#cash-prefill', text: /not a whole number of weeks before Oct 17, so weekly amounts were not carried/
    assert_blank_field 'forecast_weeks_0_receipts'
    assert_select 'textarea[name="forecast[notes]"]', @forecast_values[:notes]
    get cash_forecast_path(day: '2026-10-21', currency: 'CAD', prefill: 'none')
    assert_select '#cash-prefill', count: 0
    assert_blank_field 'forecast_weeks_0_receipts'
    assert_select 'a[href=?]', cash_forecast_path(day: '2026-10-21', currency: 'CAD'), text: 'Start from the latest CAD scenario'
    assert_difference 'ReconciliationDocument.count', 1 do
      post cash_forecast_path, params: { intent: 'retain', forecast: @forecast_values.merge(baseline_digest: baseline, prefilled_from: source.id) }
    end
    assert_equal source.id, ReconciliationDocument.where(kind: 'cash_forecast').last.metadata['prefilled_from_document_id']
    assert_equal source.id, JSON.parse(ReconciliationDocument.where(kind: 'cash_forecast').last.original_bytes)['prefilled_from_document_id']
    post cash_forecast_path, params: { intent: 'retain', forecast: @forecast_values.merge(baseline_digest: baseline, prefilled_from: @original.id, notes: 'Another synthetic plan.') }
    assert_nil ReconciliationDocument.where(kind: 'cash_forecast').last.metadata['prefilled_from_document_id']
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
        assert_select 'a[href=?]', financial_close_path(day: @day), text: 'Open day close'
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
