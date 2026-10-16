# frozen_string_literal: true

require 'test_helper'

class ReconciliationWorkflowUxTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    @user = User.create!(tenant: @tenant, email: 'retention-ux@example.com', password: 'password123', role: 'admin', name: 'Reviewer')
    post login_path, params: { email: @user.email, password: 'password123' }
    Current.tenant = @tenant
    @doc = ReconciliationEvidence.retain!(bytes: "cash,12.00\n", filename: 'daily-control.csv', source: 'bank', kind: 'register_control',
      from: '2026-10-14', to: '2026-10-14', metadata: { 'currency' => 'USD', 'cash' => 1200 })
  end
  teardown { Current.reset }

  test 'library finds originals across dates without exposing other tenants' do
    get reconciliation_documents_path, params: { q: 'DAILY-CONTROL', from: '2026-10-01', to: '2026-10-31' }
    assert_response :success
    assert_select 'h1', 'Document retention library'
    assert_includes response.body, 'daily-control.csv'
    assert_equal 'no-store', response.headers['Cache-Control']
    other = Tenant.create!(name: 'Foreign UX', subdomain: 'foreign-ux')
    @user.update!(tenant: other)
    get reconciliation_documents_path
    refute_includes response.body, 'daily-control.csv'
  end

  test 'correction action pins the day and context while preserving the previous original' do
    get daily_reconciliations_path, params: { correct: @doc.id, day: '2026-10-20' }
    assert_response :success
    assert_select 'input[name="evidence[supersedes_id]"][value=?]', @doc.id.to_s
    assert_select 'input[name="evidence[period_from]"][value="2026-10-14"]'
    assert_select 'input[name="evidence[currency]"][value="USD"]'
    file = Tempfile.new(['correction', '.csv'])
    file.write("cash,13.00\n")
    file.rewind
    post daily_reconciliations_path, params: { file: Rack::Test::UploadedFile.new(file.path, 'text/csv'),
      evidence: { source: 'bank', kind: 'register_control', period_from: '2026-10-14', period_to: '2026-10-14',
        currency: 'USD', location_id: '', cash: '13.00', supersedes_id: @doc.id } }
    assert_redirected_to daily_reconciliations_path(day: '2026-10-14')
    assert_equal "cash,12.00\n", @doc.reload.original_bytes
    newer = ReconciliationDocument.last
    assert_equal @doc.id, newer.supersedes_id
    get daily_reconciliations_path(day: '2026-10-14')
    assert_includes response.body, 'Previous version'
    assert_includes response.body, "correct=#{newer.id}"
    get daily_reconciliations_path(correct: @doc.id)
    assert_response :redirect
  ensure
    file&.close!
  end

  test 'failed attachment and stale review preserve input and the selected business day' do
    assert_no_difference 'ReconciliationDocument.count' do
      post daily_reconciliations_path, params: { evidence: { source: 'bank', kind: 'invoice', period_from: '2026-10-14', period_to: '2026-10-14', note: 'Keep my note' } }
    end
    assert_response :unprocessable_entity
    assert_select 'input[name="day"][value="2026-10-14"]'
    assert_select 'textarea[name="evidence[note]"]', 'Keep my note'
    assert_select '[role="alert"]', /Select the original file again/
    post review_daily_reconciliations_path, params: { day: '2026-10-14', report_digest: 'stale', status: 'needs_attention', notes: 'Follow up on fee report' }
    assert_response :unprocessable_entity
    assert_select 'textarea[name="notes"]', 'Follow up on fee report'
    assert_select 'input[name="day"][value="2026-10-14"]'
    assert_equal 0, DailyReconciliationReview.count
  end

  test 'report readers can search but cannot open a correction and cashiers cannot browse' do
    @user.update!(role: 'reporting')
    get reconciliation_documents_path
    assert_response :success
    assert_select 'a', text: 'Correct this control', count: 0
    get daily_reconciliations_path(correct: @doc.id)
    assert_redirected_to root_path
    @user.update!(role: 'cashier')
    get reconciliation_documents_path
    assert_redirected_to root_path
  end
end
