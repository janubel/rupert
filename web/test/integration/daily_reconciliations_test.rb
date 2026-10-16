# frozen_string_literal: true

require 'test_helper'

class DailyReconciliationsTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    @user = User.create!(tenant: @tenant, email: 'reconciliation-review@example.com', password: 'password123', role: 'admin', name: 'Reviewer')
    post login_path, params: { email: @user.email, password: 'password123' }
    Current.tenant = @tenant
  end
  teardown { Current.reset }

  test 'page CSV retention downloads and review version checks' do
    get daily_reconciliations_path(day: '2026-10-14')
    assert_response :success
    assert_select 'h1', 'Daily reconciliation & documents'
    assert_equal 'no-store', response.headers['Cache-Control']
    get daily_reconciliations_path(format: :csv, day: '2026-10-14')
    assert_response :success
    assert_includes response.body, 'Daily reconciliation'
    post archive_daily_reconciliations_path(day: '2026-10-14')
    assert_redirected_to daily_reconciliations_path(day: '2026-10-14')
    doc = ReconciliationDocument.last
    get document_daily_reconciliation_path(doc)
    assert_response :success
    assert_equal doc.original_bytes, response.body
    digest = DailyMoneyReconciliation.new(day: '2026-10-14').digest
    post review_daily_reconciliations_path, params: { day: '2026-10-14', report_digest: digest, status: 'reviewed', notes: 'No source controls yet; follow up.' }
    assert_equal 1, DailyReconciliationReview.count
    assert_no_difference 'DailyReconciliationReview.count' do
      post review_daily_reconciliations_path, params: { day: '2026-10-14', report_digest: 'old', status: 'reviewed', notes: 'Stale' }
    end
    assert_match(/changed/, flash[:alert])
  end

  test 'upload retains exact bytes and does not create sales' do
    file = Tempfile.new(['reconciliation', '.csv'])
    file.write("total,12.34\n")
    file.rewind
    assert_no_difference ['Core::Order.count', 'Core::Payment.count', 'LedgerEntry.count'] do
      post daily_reconciliations_path, params: { file: Rack::Test::UploadedFile.new(file.path, 'text/csv'),
        evidence: { source: 'ctrax', kind: 'register_control', period_from: '2026-10-14', period_to: '2026-10-14', currency: 'USD', cash: '12.34' } }
    end
    assert_redirected_to daily_reconciliations_path(day: '2026-10-14')
    doc = ReconciliationDocument.last
    assert_equal 1234, doc.metadata['cash']
    assert_equal "total,12.34\n", doc.original_bytes
  ensure
    file&.close!
  end

  test 'reporting read role can read but cannot upload archive or review' do
    @user.update!(role: 'reporting')
    get daily_reconciliations_path
    assert_response :success
    post archive_daily_reconciliations_path
    assert_redirected_to root_path
    post review_daily_reconciliations_path
    assert_redirected_to root_path
    post daily_reconciliations_path
    assert_redirected_to root_path
  end

  test 'cashiers cannot read documents or reports and tenant mismatch returns not found' do
    doc = ReconciliationEvidence.retain!(bytes: 'private', filename: 'private.txt', source: 'bank', kind: 'bank_statement', from: '2026-10-14', to: '2026-10-14')
    other = Tenant.create!(name: 'Foreign documents', subdomain: 'foreign-documents')
    @user.update!(tenant: other)
    get document_daily_reconciliation_path(doc)
    assert_response :not_found
    @user.update!(role: 'cashier', tenant: @tenant)
    get daily_reconciliations_path
    assert_redirected_to root_path
    get document_daily_reconciliation_path(doc)
    assert_redirected_to root_path
  end
end
