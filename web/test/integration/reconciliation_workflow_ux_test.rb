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
    assert_select 'h1', 'Source documents'
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

  test 'original cards surface overdue matches with safe review and scoped queue actions' do
    travel_to Time.zone.parse('2026-10-16 12:00') do
      values = { category: 'missing_report', source: 'bank', document_kind: 'register_control', currency: 'USD',
        period_from: '2026-10-14', period_to: '2026-10-14', title: 'Missing register report', notes: 'Check for the original.',
        due_on: '2026-10-15', submission_key: SecureRandom.uuid, created_by: @user }
      items = 4.times.map { |i| ReconciliationFollowUp.create!(values.merge(title: "Missing register report #{i}", submission_key: SecureRandom.uuid)) }
      ReconciliationFollowUp.create!(values.merge(title: 'Wrong currency', currency: 'CAD', submission_key: SecureRandom.uuid))
      ReconciliationFollowUp.create!(values.merge(title: 'Other location', location_id: 'different', submission_key: SecureRandom.uuid))
      ReconciliationFollowUp.create!(values.merge(title: 'Already closed', status: 'closed', submission_key: SecureRandom.uuid))
      ReconciliationFollowUp.create!(values.merge(title: 'Outside coverage', period_from: '2026-10-13', period_to: '2026-10-13', submission_key: SecureRandom.uuid))
      assert_no_enqueued_jobs do
        assert_no_difference ['ReconciliationFollowUpEvent.count', 'ActionMailer::Base.deliveries.size'] do
          get reconciliation_documents_path(q: 'daily-control')
          assert_response :success
          assert_select "#evidence-#{@doc.id} h2", text: '4 matching open follow-ups'
          assert_select "#evidence-#{@doc.id} a", text: 'Review & link this original', count: 3
          assert_includes response.body, '1 day overdue'
          assert_select 'a[href=?]', reconciliation_follow_ups_path(original: @doc.id), text: 'See all 4 matching follow-ups'
          get reconciliation_follow_ups_path(original: @doc.id)
          assert_response :success
          items.each { |item| assert_includes response.body, item.title }
          ['Wrong currency', 'Other location', 'Already closed', 'Outside coverage'].each { |title| refute_includes response.body, title }
          assert_select 'input[name="original"][value=?]', @doc.id.to_s
          get reconciliation_follow_up_path(items.first, evidence: @doc.id)
          assert_select 'select[name="follow_up[document_id]"] option[selected][value=?]', @doc.id.to_s
          assert_nil items.first.reload.document_id
          assert_equal 'open', items.first.status
        end
      end
      items.first.update!(document_id: @doc.id, notes: 'File reviewed; questions remain.')
      get reconciliation_documents_path(q: 'daily-control')
      assert_includes response.body, 'This original is linked'
      @user.update!(role: 'reporting')
      get reconciliation_documents_path(q: 'daily-control')
      assert_select 'a', text: 'Review & link this original', count: 0
      assert_select 'a', text: 'View follow-up', count: 3
      foreign = Tenant.create!(name: 'Foreign original match', subdomain: 'foreign-original-match')
      @user.update!(tenant: foreign)
      get reconciliation_follow_ups_path(original: @doc.id)
      assert_response :not_found
    end
  end

  test 'request search keeps close context across filters pages and explicit evidence review without changing history' do
    travel_to Time.zone.parse('2026-10-16 12:00') do
      item = ReconciliationFollowUp.create!(category: 'missing_report', source: 'bank', document_kind: 'bank_statement',
        period_from: '2026-10-01', period_to: '2026-10-31', title: 'October statement needed', notes: 'Review the covered original.',
        due_on: '2026-10-13', owner: @user, created_by: @user, submission_key: SecureRandom.uuid)
      original = ReconciliationEvidence.retain!(bytes: 'Synthetic full statement', filename: 'full-statement.txt', source: 'bank', kind: 'bank_statement', from: '2026-10-01', to: '2026-10-31')
      partial = ReconciliationEvidence.retain!(bytes: 'Synthetic partial statement', filename: 'partial-statement.txt', source: 'bank', kind: 'bank_statement', from: '2026-10-01', to: '2026-10-14')
      context = { follow_up: item.id, close_day: '2026-10-14' }
      assert_no_enqueued_jobs do
        assert_no_difference ['ReconciliationFollowUp.count', 'ReconciliationFollowUpEvent.count', 'ActionMailer::Base.deliveries.size'] do
          get reconciliation_documents_path(context.merge(source: 'bank', from: '2026-10-14', to: '2026-10-14'))
          assert_response :success
          assert_select '[aria-label="Report request being resolved"]', text: /3 days overdue/
          assert_select 'form[role="search"] input[name="follow_up"][value=?]', item.id.to_s
          assert_select 'form[role="search"] input[name="close_day"][value="2026-10-14"]'
          assert_select 'a[href=?]', financial_close_path(day: '2026-10-14', anchor: 'close-follow-ups'), text: 'Back to close · Oct 14'
          assert_select "#evidence-#{original.id} a[href=?]", reconciliation_follow_up_path(item, evidence: original.id, close_day: '2026-10-14', anchor: 'record-progress'), text: 'Review & use for this request'
          assert_select "#evidence-#{partial.id} a", text: 'Review & use for this request', count: 0
          assert_select "#evidence-#{@doc.id} a", text: 'Review & use for this request', count: 0
          get reconciliation_documents_path(context.merge(q: 'absent'))
          assert_select 'a', text: 'Track missing report', count: 0
          assert_select 'a[href=?]', reconciliation_follow_up_path(item, close_day: '2026-10-14', anchor: 'record-progress'), text: 'Return to this request'
          get reconciliation_documents_path(context.merge(cursor: 'expired'))
          assert_select '[role="alert"]', text: /expired/
          assert_select 'input[name="follow_up"][value=?]', item.id.to_s
          get reconciliation_follow_up_path(item, evidence: original.id, close_day: '2026-10-14')
          assert_select 'select[name="follow_up[document_id]"] option[selected][value=?]', original.id.to_s
          assert_select 'button[value="close"]', text: 'Save and return to financial close'
          assert_nil item.reload.document_id
        end
      end
      25.times { |i| ReconciliationEvidence.retain!(bytes: "Synthetic statement #{i}", filename: "statement-#{i}.txt", source: 'bank', kind: 'bank_statement', from: '2026-10-01', to: '2026-10-31') }
      get reconciliation_documents_path(context.merge(source: 'bank'))
      older = css_select('nav[aria-label="Document library pages"] a').find { |link| link.text.include?('Older documents') }['href']
      assert_includes older, "follow_up=#{item.id}"
      assert_includes older, 'close_day=2026-10-14'
      get older
      assert_response :success
      assert_select 'input[name="close_day"][value="2026-10-14"]'
      assert_select 'a', text: 'Back to newest matches'
      @user.update!(role: 'reporting')
      get reconciliation_documents_path(context.merge(q: 'full-statement'))
      assert_select 'a', text: 'Review & use for this request', count: 0
      assert_select 'a', text: 'Add missing original', count: 0
      assert_select 'a', text: 'Return to this request'
    end
  end

  test 'library context rejects foreign requests and invalid close days and preserves valid close-only tracking' do
    item = ReconciliationFollowUp.create!(category: 'missing_report', source: 'bank', document_kind: 'register_control', currency: 'USD',
      period_from: '2026-10-14', period_to: '2026-10-14', title: 'Register report needed', notes: 'Review the original.',
      due_on: '2026-10-15', created_by: @user, submission_key: SecureRandom.uuid)
    ['2026-10-13', 'https://example.com'].each do |day|
      get reconciliation_documents_path(follow_up: item.id, close_day: day)
      assert_select '[aria-label="Report request being resolved"]'
      assert_select 'input[name="close_day"]', count: 0
      assert_select 'a', text: /Back to close/, count: 0
    end
    get reconciliation_documents_path(follow_up: item.id, close_day: '2026-10-14', source: 'bank')
    assert_select "#evidence-#{@doc.id} a", text: 'Review & use for this request'
    item.update!(currency: 'USD', status: 'closed', notes: 'Documented exception reviewed.')
    get reconciliation_documents_path(follow_up: item.id, close_day: '2026-10-14')
    assert_select 'a', text: 'Review & use for this request', count: 0
    assert_select '[aria-label="Report request being resolved"]', text: /This request is closed/
    get reconciliation_documents_path(source: 'bank', from: '2026-10-14', to: '2026-10-14', close_day: '2026-10-14', q: 'absent')
    assert_select 'a[href=?]', new_reconciliation_follow_up_path(source: 'bank', period_from: '2026-10-14', period_to: '2026-10-14', close_day: '2026-10-14'), text: 'Track missing report'
    assert_select 'a[href=?]', financial_close_path(day: '2026-10-14', anchor: 'close-missing-reports'), text: 'Back to day close'
    other = Tenant.create!(name: 'Foreign request library', subdomain: 'foreign-request-library')
    @user.update!(tenant: other)
    get reconciliation_documents_path(follow_up: item.id, close_day: '2026-10-14')
    assert_response :not_found
  end

  test 'empty library search carries source and coverage into local missing report tracking' do
    get reconciliation_documents_path(source: 'bank', from: '2026-10-01', to: '2026-10-31', q: 'not-present')
    assert_select 'a[href=?]', new_reconciliation_follow_up_path(source: 'bank', period_from: '2026-10-01', period_to: '2026-10-31'), text: 'Track missing report'
    assert_includes response.body, 'No email or message is sent.'
    @user.update!(role: 'reporting')
    get reconciliation_documents_path(q: 'not-present')
    assert_select 'a', text: 'Track missing report', count: 0
  end
end
