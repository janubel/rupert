# frozen_string_literal: true

require 'test_helper'

class ReconciliationFollowUpsTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    @user = User.create!(tenant: @tenant, email: 'follow-up-reviewer@example.com', name: 'Follow-up reviewer', role: 'admin', password: 'password123')
    post login_path, params: { email: @user.email, password: 'password123' }
    Current.tenant = @tenant
    @values = { category: 'missing_report', source: 'bank', document_kind: 'bank_statement', period_from: '2026-10-01', period_to: '2026-10-31',
      title: 'October statement needed', notes: 'Ask the bookkeeper for the original.', due_on: '2026-10-15', owner_id: @user.id, submission_key: SecureRandom.uuid }
  end
  teardown { Current.reset }

  test 'tracking and queue progress are local only and validation keeps the user on the form' do
    travel_to Time.zone.parse('2026-10-16 12:00') do
      assert_no_difference 'ActionMailer::Base.deliveries.size' do
        assert_no_enqueued_jobs do
          post reconciliation_follow_ups_path, params: { follow_up: @values }
          item = ReconciliationFollowUp.last
          assert_redirected_to reconciliation_follow_up_path(item)
          assert_includes flash[:notice], 'No email or message was sent.'
          patch reconciliation_follow_up_path(item), params: { return_to: 'overdue', follow_up: { status: 'waiting', notes: '', lock_version: 0 } }
          assert_response :unprocessable_entity
          assert_equal 1, item.events.count
          patch reconciliation_follow_up_path(item), params: { return_to: 'overdue', follow_up: { status: 'waiting', notes: 'Original still outstanding. Check again tomorrow.', due_on: '2026-10-17', lock_version: 0 } }
          assert_redirected_to reconciliation_follow_ups_path(status: 'overdue')
          assert_equal 'waiting', item.reload.status
          assert_equal 2, item.events.count
          get reconciliation_follow_up_path(item)
          assert_select 'button[data-date="2026-10-16"]', text: 'Today'
          assert_select 'button[data-date="2026-10-19"]', text: 'In 3 days'
          assert_includes response.body, 'No email or message is sent.'
        end
      end
    end
  end

  test 'requested upload suggests matching evidence without linking or closing and ignores foreign suggestions' do
    item = ReconciliationFollowUp.create!(@values.merge(created_by: @user))
    file = Tempfile.new(['follow-up-original', '.txt'])
    file.write('Synthetic bank statement')
    file.close
    assert_no_enqueued_jobs do
      post daily_reconciliations_path, params: { request_id: item.id, file: Rack::Test::UploadedFile.new(file.path, 'text/plain'),
        evidence: { source: 'bank', kind: 'bank_statement', period_from: '2026-10-01', period_to: '2026-10-31' } }
    end
    doc = ReconciliationDocument.last
    assert_redirected_to reconciliation_follow_up_path(item, evidence: doc.id, anchor: 'record-progress')
    assert_nil item.reload.document_id
    assert_equal 'open', item.status
    assert_equal 1, item.events.count
    follow_redirect!
    assert_select 'select[name="follow_up[document_id]"] option[selected][value=?]', doc.id.to_s
    assert_select 'button[data-evidence-id=?]', doc.id.to_s, text: 'Use this original'
    assert_includes response.body, 'Nothing has been linked or closed yet.'
    other = Tenant.create!(name: 'Foreign original', subdomain: 'foreign-original-suggestion')
    foreign = Current.set(tenant: other) do
      ReconciliationEvidence.retain!(bytes: 'private file', filename: 'foreign-private-original.txt', source: 'bank', kind: 'bank_statement', from: '2026-10-01', to: '2026-10-31')
    end
    get reconciliation_follow_up_path(item, evidence: foreign.id)
    assert_response :success
    refute_includes response.body, foreign.filename
    assert_select 'select[name="follow_up[document_id]"] option[value=?]', foreign.id.to_s, count: 0
    assert_includes response.body, 'No link was changed.'
    assert_nil item.reload.document_id
  ensure
    file&.unlink
  end

  test 'overdue actions lead the overview and original actions respect read access and linked evidence' do
    travel_to Time.zone.parse('2026-10-16 12:00') do
      overdue = ReconciliationFollowUp.create!(@values.merge(created_by: @user))
      assert_no_difference ['ReconciliationFollowUp.count', 'ReconciliationFollowUpEvent.count'] do
        get overview_reconciliation_follow_ups_path
        assert_response :success
        assert_operator response.body.index('id="priority-follow-ups"'), :<, response.body.index('id="report-gaps"')
        assert_operator response.body.index('id="report-gaps"'), :<, response.body.index('id="business-days"')
        assert_select '#priority-follow-ups a[href=?]', reconciliation_follow_up_path(overdue, anchor: 'record-progress'), text: 'Record progress'
        assert_select '#priority-follow-ups a[href=?]', daily_reconciliations_path(request: overdue.id, anchor: 'upload-document'), text: 'Add original'
      end
      get reconciliation_follow_up_path(overdue, anchor: 'record-progress')
      assert_select '#record-progress textarea[name="follow_up[notes]"]'
      get daily_reconciliations_path(day: '2026-10-14')
      assert_select 'a[href=?]', reconciliation_follow_ups_path(status: 'overdue'), text: 'Work overdue follow-ups'
      get reconciliation_documents_path
      assert_select 'section[aria-label="Report follow-up actions"] a[href=?]', reconciliation_follow_ups_path(status: 'overdue'), text: 'Overdue follow-ups · 1'
      doc = ReconciliationEvidence.retain!(bytes: 'original', filename: 'statement.txt', source: 'bank', kind: 'bank_statement', from: '2026-10-01', to: '2026-10-31')
      overdue.update!(document: doc, notes: 'Original retained; investigate remaining questions.')
      @user.update!(role: 'reporting')
      get reconciliation_follow_ups_path
      assert_select 'a[href=?]', document_daily_reconciliation_path(doc.id), text: 'Download linked original'
      assert_select 'a', text: 'Record progress', count: 0
      assert_select 'a', text: 'Add original', count: 0
    end
  end

  test 'across day overview is read only and queue shortcuts combine purpose evidence and due date' do
    travel_to Time.zone.parse('2026-10-16 12:00') do
      item = ReconciliationFollowUp.create!(@values.merge(created_by: @user, due_on: Date.current))
      ReconciliationFollowUp.create!(@values.merge(category: 'difference', title: 'Different investigation', due_on: Date.current, submission_key: SecureRandom.uuid))
      assert_no_difference ['ReconciliationDocument.count', 'ReconciliationFollowUp.count', 'ReconciliationFollowUpEvent.count'] do
        get overview_reconciliation_follow_ups_path(ending_on: '2026-10-15')
        assert_response :success
        assert_select 'article[aria-label^="Business date"]', count: 7
        assert_includes response.body, 'This view does not certify a day as complete.'
        assert_includes response.body, 'October statement needed'
      end
      get reconciliation_follow_ups_path(status: 'today', category: 'missing_report', evidence: 'missing', owner: 'mine', day: '2026-10-12')
      assert_response :success
      assert_includes response.body, 'October statement needed'
      refute_includes response.body, 'Different investigation'
      assert_includes response.body, 'Due today'
      assert_includes response.body, 'Ask the bookkeeper for the original.'
      doc = ReconciliationEvidence.retain!(bytes: 'statement', filename: 'statement.txt', source: 'bank', kind: 'bank_statement', from: '2026-10-01', to: '2026-10-31')
      item.update!(document: doc, notes: 'Original linked; needs review.')
      get reconciliation_follow_ups_path(category: 'missing_report', evidence: 'missing')
      refute_includes response.body, 'October statement needed'
      get overview_reconciliation_follow_ups_path(ending_on: 'invalid')
      assert_redirected_to overview_reconciliation_follow_ups_path
    end
  end

  test 'report request replay is idempotent and retains encrypted progress history with stale update protection' do
    assert_difference ['ReconciliationFollowUp.count', 'ReconciliationFollowUpEvent.count'], 1 do
      post reconciliation_follow_ups_path, params: { follow_up: @values }
    end
    item = ReconciliationFollowUp.last
    assert_redirected_to reconciliation_follow_up_path(item)
    assert_no_difference 'ReconciliationFollowUp.count' do
      post reconciliation_follow_ups_path, params: { follow_up: @values }
    end
    patch reconciliation_follow_up_path(item), params: { follow_up: { title: 'Statement from bank', status: 'waiting', notes: 'Requested original from bookkeeper.', due_on: '2026-10-20', lock_version: 0 } }
    assert_response :redirect
    assert_equal 'waiting', item.reload.status
    assert_equal 2, item.events.count
    assert_equal 'October statement needed', item.events.first.details['title']
    assert_equal 'Statement from bank', item.events.last.details['title']
    patch reconciliation_follow_up_path(item), params: { follow_up: { status: 'closed', notes: 'Do not lose my closing note.', lock_version: 0 } }
    assert_response :unprocessable_entity
    assert_select 'textarea[name="follow_up[notes]"]', 'Do not lose my closing note.'
    assert_equal 'waiting', item.reload.status
    assert_equal 2, item.events.count
    raw = ActiveRecord::Base.connection.select_one("SELECT title, notes FROM reconciliation_follow_ups WHERE id = #{item.id}")
    refute_includes raw['title'], 'Statement from bank'
    refute_includes raw['notes'], 'bookkeeper'
    event = item.events.first
    assert_equal @values[:notes], event.details['notes']
    refute event.update(details_json: '{}')
    assert_raises(ActiveRecord::RecordNotDestroyed) { item.destroy! }
  end

  test 'invalid assignments evidence and due dates preserve entered text without changing history' do
    item = ReconciliationFollowUp.create!(@values.merge(created_by: @user))
    other = Tenant.create!(name: 'Other followups', subdomain: 'other-followups')
    foreign_user = User.create!(tenant: other, email: 'foreign-followup@example.com', name: 'Foreign private owner', role: 'admin', password: 'password123')
    patch reconciliation_follow_up_path(item), params: { follow_up: { owner_id: foreign_user.id, due_on: '', status: 'closed', notes: 'Keep this reason', lock_version: 0 } }
    assert_response :unprocessable_entity
    assert_select 'textarea[name="follow_up[notes]"]', 'Keep this reason'
    refute_includes response.body, 'Foreign private owner'
    assert_equal 'open', item.reload.status
    assert_equal 1, item.events.count
    doc = ReconciliationEvidence.retain!(bytes: 'invoice', filename: 'invoice.txt', source: 'bank', kind: 'invoice', from: '2026-10-01', to: '2026-10-31')
    patch reconciliation_follow_up_path(item), params: { follow_up: { document_id: doc.id, notes: 'Wrong kind', lock_version: 0 } }
    assert_response :unprocessable_entity
    assert_nil item.reload.document_id
    get daily_reconciliations_path(request: item.id)
    assert_response :success
    assert_select 'input[name="request_id"][value=?]', item.id.to_s
    assert_select 'select[name="evidence[source]"] option[selected][value="bank"]'
    assert_select 'input[name="evidence[period_to]"][value="2026-10-31"]'
  end

  test 'matching retained file can be linked but upload and closing do not certify source totals' do
    item = ReconciliationFollowUp.create!(@values.merge(created_by: @user))
    doc = ReconciliationEvidence.retain!(bytes: 'statement', filename: 'statement.txt', source: 'bank', kind: 'bank_statement', from: '2026-10-01', to: '2026-10-31')
    get reconciliation_follow_up_path(item)
    assert_select 'select[name="follow_up[document_id]"] option[value=?]', doc.id.to_s
    assert_equal 'open', item.reload.status
    patch reconciliation_follow_up_path(item), params: { follow_up: { status: 'closed', notes: 'Original reviewed and retained; remaining questions documented.', document_id: doc.id, lock_version: 0 } }
    assert_response :redirect
    assert_equal 'closed', item.reload.status
    assert_equal doc.id, item.document_id
    assert_equal 2, item.events.count
    assert_equal 0, DailyReconciliationReview.count
    DataRetention.prune_all!(now: Time.zone.parse('2040-01-01'))
    assert ReconciliationFollowUp.exists?(item.id)
    assert_equal 2, item.events.count
  end

  test 'queue shows overdue and assigned filters across dates and isolates tenants and readers' do
    item = ReconciliationFollowUp.create!(@values.merge(created_by: @user))
    travel_to Time.zone.parse('2026-10-16 12:00') do
      get reconciliation_follow_ups_path(status: 'overdue', owner: 'mine')
      assert_response :success
      assert_includes response.body, 'October statement needed'
      assert_includes response.body, 'Overdue'
    end
    @user.update!(role: 'reporting')
    get reconciliation_follow_up_path(item)
    assert_response :success
    assert_select 'input[value="Save progress"]', count: 0
    patch reconciliation_follow_up_path(item), params: { follow_up: { status: 'closed', notes: 'No permission', lock_version: 0 } }
    assert_response :redirect
    assert_equal 'open', item.reload.status
    other = Tenant.create!(name: 'Hidden followups', subdomain: 'hidden-followups')
    @user.update!(tenant: other)
    get reconciliation_follow_ups_path
    refute_includes response.body, 'October statement needed'
    get reconciliation_follow_up_path(item)
    assert_response :not_found
  end
end
