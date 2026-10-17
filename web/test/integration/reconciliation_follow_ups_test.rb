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

  test 'close context follows a missing request through validation replay upload progress and resolution' do
    file = nil
    get new_reconciliation_follow_up_path(period_from: '2026-10-01', period_to: '2026-10-31', close_day: '2026-10-14')
    assert_select 'input[name="close_day"][value="2026-10-14"]'
    post reconciliation_follow_ups_path, params: { close_day: '2026-10-14', follow_up: @values.merge(notes: '') }
    assert_response :unprocessable_entity
    assert_select 'input[name="close_day"][value="2026-10-14"]'
    assert_no_enqueued_jobs do
      assert_no_difference 'ActionMailer::Base.deliveries.size' do
        post reconciliation_follow_ups_path, params: { close_day: '2026-10-14', follow_up: @values }
        item = ReconciliationFollowUp.last
        assert_redirected_to reconciliation_follow_up_path(item, close_day: '2026-10-14')
        assert_no_difference 'ReconciliationFollowUp.count' do
          post reconciliation_follow_ups_path, params: { close_day: '2026-10-14', follow_up: @values }
        end
        assert_redirected_to reconciliation_follow_up_path(item, close_day: '2026-10-14')
        follow_redirect!
        assert_select 'button[type="button"][data-decision="waiting"]', text: 'Waiting on report'
        assert_select 'button[type="button"][data-decision="closed"]', text: 'Resolve follow-up'
        assert_select 'a[href=?]', daily_reconciliations_path(day: item.period_from.iso8601, request: item.id, close_day: '2026-10-14', anchor: 'upload-document'), text: 'Add original report'
        get daily_reconciliations_path(request: item.id, close_day: '2026-10-14')
        assert_select '#upload-document input[name="close_day"][value="2026-10-14"]'
        post daily_reconciliations_path, params: { request_id: item.id, close_day: '2026-10-14', evidence: { source: 'bank', kind: 'bank_statement', period_from: '2026-10-01', period_to: '2026-10-31' } }
        assert_response :unprocessable_entity
        assert_select '#upload-document input[name="close_day"][value="2026-10-14"]'
        file = Tempfile.new(['resolution-original', '.txt'])
        file.write('Synthetic covered original')
        file.close
        post daily_reconciliations_path, params: { request_id: item.id, close_day: '2026-10-14', file: Rack::Test::UploadedFile.new(file.path, 'text/plain'), evidence: { source: 'bank', kind: 'bank_statement', period_from: '2026-10-01', period_to: '2026-10-31' } }
        doc = ReconciliationDocument.last
        assert_redirected_to reconciliation_follow_up_path(item, evidence: doc.id, close_day: '2026-10-14', anchor: 'record-progress')
        assert_nil item.reload.document_id
        assert_equal 'open', item.status
        patch reconciliation_follow_up_path(item), params: { close_day: '2026-10-14', follow_up: { status: 'waiting', notes: 'Original retained; review remaining questions tomorrow.', document_id: doc.id, lock_version: item.lock_version } }
        assert_redirected_to reconciliation_follow_up_path(item, close_day: '2026-10-14')
        patch reconciliation_follow_up_path(item), params: { close_day: '2026-10-14', return_to: 'close', follow_up: { status: 'closed', notes: 'Covered original reviewed; request resolved.', lock_version: item.reload.lock_version } }
        assert_redirected_to financial_close_path(day: '2026-10-14', anchor: 'close-follow-ups')
        assert_equal 'closed', item.reload.status
        assert_equal doc.id, item.document_id
        assert_equal 3, item.events.count
        assert_equal 'Covered original reviewed; request resolved.', item.events.last.details['notes']
      end
    end
  ensure
    file&.unlink
  end

  test 'upload close context rejects uncovered dates and foreign requests' do
    item = ReconciliationFollowUp.create!(@values.merge(created_by: @user))
    ['2026-09-30', 'https://example.com'].each do |context|
      get daily_reconciliations_path(request: item.id, close_day: context)
      assert_select '#upload-document input[name="close_day"]', count: 0
    end
    other = Tenant.create!(name: 'Foreign request', subdomain: 'foreign-close-request')
    foreign = Current.set(tenant: other) do
      author = User.create!(tenant: other, email: 'foreign-author@example.com', role: 'admin', password: 'password123')
      ReconciliationFollowUp.create!(@values.merge(created_by: author, owner_id: nil, submission_key: SecureRandom.uuid))
    end
    get daily_reconciliations_path(request: foreign.id, close_day: '2026-10-14')
    assert_response :not_found
  end

  test 'progress returns to a validated covered close day and preserves context on errors' do
    item = ReconciliationFollowUp.create!(@values.merge(created_by: @user))
    get reconciliation_follow_up_path(item, close_day: '2026-10-14')
    assert_select 'input[name="close_day"][value="2026-10-14"]'
    assert_select 'form[data-busy="false"] button[name="return_to"][value="close"]', text: 'Save and return to financial close'
    assert_select 'a[href=?]', financial_close_path(day: '2026-10-14', anchor: 'close-follow-ups'), text: 'Back to day close'
    assert_no_enqueued_jobs do
      assert_no_difference ['ActionMailer::Base.deliveries.size', 'ReconciliationDocument.count'] do
        assert_no_difference 'ReconciliationFollowUpEvent.count' do
          patch reconciliation_follow_up_path(item), params: { close_day: '2026-10-14', return_to: 'close', follow_up: { notes: '', lock_version: item.lock_version } }
        end
        assert_response :unprocessable_entity
        assert_select 'input[name="close_day"][value="2026-10-14"]'
        assert_difference 'ReconciliationFollowUpEvent.count', 1 do
          patch reconciliation_follow_up_path(item), params: { close_day: '2026-10-14', return_to: 'close', follow_up: { notes: 'Original outstanding; next step recorded locally.', lock_version: item.lock_version } }
        end
        assert_redirected_to financial_close_path(day: '2026-10-14', anchor: 'close-follow-ups')
      end
    end
    ['2026-09-30', 'https://example.com'].each do |context|
      get reconciliation_follow_up_path(item, close_day: context)
      assert_select 'input[name="close_day"]', count: 0
      assert_select 'button[value="close"]', count: 0
    end
    patch reconciliation_follow_up_path(item), params: { close_day: 'https://example.com', return_to: 'close', follow_up: { notes: 'Second local update.', lock_version: item.reload.lock_version } }
    assert_redirected_to reconciliation_follow_up_path(item)
    @user.update!(role: 'reporting')
    get reconciliation_follow_up_path(item, close_day: '2026-10-14')
    assert_select 'a', text: 'Back to day close'
    assert_select 'button[value="close"]', count: 0
  end

  test 'save and work next overdue picks the latest earliest due item across dates and changes only the current request' do
    travel_to Time.zone.parse('2026-10-16 12:00') do
      current = ReconciliationFollowUp.create!(@values.merge(created_by: @user))
      next_item = ReconciliationFollowUp.create!(@values.merge(created_by: @user, title: 'Earlier October request', due_on: '2026-10-12', submission_key: SecureRandom.uuid))
      later = ReconciliationFollowUp.create!(@values.merge(created_by: @user, title: 'September request', period_from: '2026-09-01', period_to: '2026-09-30', due_on: '2026-10-13', submission_key: SecureRandom.uuid))
      ReconciliationFollowUp.create!(@values.merge(created_by: @user, title: 'Already closed', status: 'closed', due_on: '2026-10-01', submission_key: SecureRandom.uuid))
      ReconciliationFollowUp.create!(@values.merge(created_by: @user, title: 'Due today', due_on: Date.current, submission_key: SecureRandom.uuid))
      get reconciliation_follow_up_path(current, close_day: '2026-10-14')
      assert_select '[aria-label="Continue overdue follow-ups across days"]', text: /Earlier October request/
      assert_select 'form[data-busy="false"] button[name="return_to"][value="next_overdue"]', text: 'Save and work next overdue'
      next_item.update!(status: 'closed', notes: 'Resolved elsewhere before this form was saved.')
      assert_no_enqueued_jobs do
        assert_no_difference ['ActionMailer::Base.deliveries.size', 'ReconciliationDocument.count'] do
          assert_difference 'ReconciliationFollowUpEvent.count', 1 do
            patch reconciliation_follow_up_path(current), params: { close_day: '2026-10-14', return_to: 'next_overdue', follow_up: { status: 'waiting', due_on: '2026-10-17', notes: 'Still outstanding; next check tomorrow.', lock_version: current.lock_version } }
          end
        end
      end
      assert_redirected_to reconciliation_follow_up_path(later, anchor: 'record-progress')
      assert_equal 'waiting', current.reload.status
      assert_equal Date.new(2026, 10, 17), current.due_on
      assert_equal 1, later.events.count
      assert_equal 'open', later.reload.status
      follow_redirect!
      assert_select 'input[name="close_day"]', count: 0
      assert_select 'textarea[name="follow_up[notes]"]', text: ''
      assert_select '[aria-label="Continue overdue follow-ups across days"]', text: /No other overdue/
    end
  end

  test 'next overdue preserves a shared covered close date and excludes foreign tenant work' do
    travel_to Time.zone.parse('2026-10-16 12:00') do
      current = ReconciliationFollowUp.create!(@values.merge(created_by: @user))
      next_item = ReconciliationFollowUp.create!(@values.merge(created_by: @user, due_on: '2026-10-10', submission_key: SecureRandom.uuid))
      other = Tenant.create!(name: 'Foreign overdue', subdomain: 'foreign-overdue-continuation')
      Current.set(tenant: other) do
        author = User.create!(tenant: other, email: 'foreign-overdue-author@example.com', role: 'admin', password: 'password123')
        ReconciliationFollowUp.create!(@values.merge(created_by: author, owner_id: nil, title: 'Foreign private request', due_on: '2026-10-01', submission_key: SecureRandom.uuid))
      end
      get reconciliation_follow_up_path(current, close_day: '2026-10-14')
      refute_includes response.body, 'Foreign private request'
      patch reconciliation_follow_up_path(current), params: { close_day: '2026-10-14', return_to: 'next_overdue', follow_up: { status: 'closed', notes: 'Documented exception reviewed.', lock_version: current.lock_version } }
      assert_redirected_to reconciliation_follow_up_path(next_item, close_day: '2026-10-14', anchor: 'record-progress')
      assert_equal 'closed', current.reload.status
      assert_equal 1, next_item.events.count
      @user.update!(role: 'reporting')
      get reconciliation_follow_up_path(next_item)
      assert_select 'button[value="next_overdue"]', count: 0
      patch reconciliation_follow_up_path(next_item), params: { return_to: 'next_overdue', follow_up: { notes: 'Not allowed', lock_version: next_item.lock_version } }
      assert_redirected_to root_path
      assert_equal 1, next_item.events.count
    end
  end

  test 'next overdue does not advance on invalid or stale saves and empty fallback keeps unresolved work visible' do
    travel_to Time.zone.parse('2026-10-16 12:00') do
      current = ReconciliationFollowUp.create!(@values.merge(created_by: @user))
      get reconciliation_follow_up_path(current, close_day: '2026-10-14')
      assert_select 'button[value="next_overdue"]', text: 'Save and check overdue queue'
      assert_no_difference 'ReconciliationFollowUpEvent.count' do
        patch reconciliation_follow_up_path(current), params: { close_day: '2026-10-14', return_to: 'next_overdue', follow_up: { notes: '', lock_version: current.lock_version } }
      end
      assert_response :unprocessable_entity
      assert_select 'input[name="close_day"][value="2026-10-14"]'
      version = current.lock_version
      current.update!(notes: 'Newer reviewer update.')
      assert_no_difference 'ReconciliationFollowUpEvent.count' do
        patch reconciliation_follow_up_path(current), params: { return_to: 'next_overdue', follow_up: { notes: 'Preserve my unsaved text.', lock_version: version } }
      end
      assert_response :unprocessable_entity
      assert_select 'textarea[name="follow_up[notes]"]', 'Preserve my unsaved text.'
      patch reconciliation_follow_up_path(current), params: { return_to: 'next_overdue', follow_up: { notes: 'Still overdue, investigation continues.', lock_version: current.reload.lock_version } }
      assert_redirected_to reconciliation_follow_ups_path(status: 'overdue')
      assert_includes flash[:notice], 'No other overdue follow-ups'
      assert current.reload.overdue?
      follow_redirect!
      assert_includes response.body, current.title
    end
  end

  test 'an older reviewed or linked original remains selectable outside the recent evidence window' do
    item = ReconciliationFollowUp.create!(@values.merge(created_by: @user))
    doc = ReconciliationEvidence.retain!(bytes: 'older original', filename: 'older-statement.txt', source: 'bank', kind: 'bank_statement', from: '2026-10-01', to: '2026-10-31')
    ReconciliationFollowUp.any_instance.stubs(:matching_documents).returns([])
    get reconciliation_follow_up_path(item, evidence: doc.id)
    assert_select 'select[name="follow_up[document_id]"] option[selected][value=?]', doc.id.to_s
    assert_select 'button[data-evidence-id=?]', doc.id.to_s
    assert_nil item.reload.document_id
    item.update!(document: doc, notes: 'Original reviewed; waiting for remaining detail.')
    get reconciliation_follow_up_path(item)
    assert_select 'select[name="follow_up[document_id]"] option[selected][value=?]', doc.id.to_s
    assert_includes response.body, 'older-statement.txt'
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

  test 'selected queue survives progress validation and saving returns to its latest matching work without messages' do
    travel_to Time.zone.parse('2026-10-16 12:00') do
      item = ReconciliationFollowUp.create!(@values.merge(created_by: @user))
      queue = { status: 'overdue', source: 'bank', owner: 'mine', category: 'missing_report', evidence: 'missing', day: '2026-10-14' }
      get reconciliation_follow_ups_path(queue)
      assert_select 'a[href=?]', reconciliation_follow_up_path(item, close_day: '2026-10-14', queue: queue, anchor: 'record-progress'), text: 'Record progress'
      assert_select 'a[href=?]', overview_reconciliation_follow_ups_path(ending_on: '2026-10-14'), text: 'Across days'
      get reconciliation_follow_up_path(item, close_day: '2026-10-14', queue: queue)
      assert_select 'a[href=?]', reconciliation_follow_ups_path(queue), text: 'Back to selected queue'
      queue.each { |key, value| assert_select 'input[name=?][value=?]', "queue[#{key}]", value }
      assert_select 'form[data-busy="false"] button[name="return_to"][value="queue"]', text: 'Save and return to selected queue'
      assert_no_enqueued_jobs do
        assert_no_difference ['ActionMailer::Base.deliveries.size', 'ReconciliationDocument.count'] do
          assert_no_difference 'ReconciliationFollowUpEvent.count' do
            patch reconciliation_follow_up_path(item), params: { queue: queue, close_day: '2026-10-14', return_to: 'queue', follow_up: { notes: '', lock_version: item.lock_version } }
          end
          assert_response :unprocessable_entity
          assert_select 'input[name="queue[day]"][value="2026-10-14"]'
          assert_select 'button[value="queue"]'
          assert_difference 'ReconciliationFollowUpEvent.count', 1 do
            patch reconciliation_follow_up_path(item), params: { queue: queue, close_day: '2026-10-14', return_to: 'queue', follow_up: { status: 'waiting', due_on: Date.tomorrow.iso8601, notes: 'Synthetic next check tomorrow.', lock_version: item.lock_version } }
          end
          assert_redirected_to reconciliation_follow_ups_path(queue)
          follow_redirect!
          assert_select 'section[aria-label="Priorities in this filtered view"] article p.font-display', text: '0', count: 2
          assert_includes response.body, 'request may no longer match its filters'
        end
      end
      assert_equal 'waiting', item.reload.status
      assert_equal Date.tomorrow, item.due_on
    end
  end

  test 'selected queue survives normal saves invalid changes and stale forms with entered notes preserved' do
    item = ReconciliationFollowUp.create!(@values.merge(created_by: @user))
    doc = ReconciliationEvidence.retain!(bytes: 'Synthetic queue original', filename: 'queue-original.txt', source: 'bank', kind: 'bank_statement', from: '2026-10-01', to: '2026-10-31')
    queue = { status: 'active', source: 'bank', original: doc.id, day: '2026-10-14' }
    patch reconciliation_follow_up_path(item), params: { queue: queue, close_day: '2026-10-14', follow_up: { notes: 'Synthetic saved progress.', lock_version: item.lock_version } }
    assert_redirected_to reconciliation_follow_up_path(item, close_day: '2026-10-14', queue: queue)
    stale_version = item.reload.lock_version
    item.update!(notes: 'Synthetic concurrent update.')
    patch reconciliation_follow_up_path(item), params: { queue: queue, return_to: 'queue', follow_up: { notes: 'Keep my draft on conflict.', lock_version: stale_version } }
    assert_response :unprocessable_entity
    assert_select 'textarea[name="follow_up[notes]"]', text: 'Keep my draft on conflict.'
    assert_select 'input[name="queue[original]"][value=?]', doc.id.to_s
    patch reconciliation_follow_up_path(item), params: { queue: queue, return_to: 'queue', follow_up: { due_on: '', notes: 'Keep this invalid date draft.', lock_version: item.reload.lock_version } }
    assert_response :unprocessable_entity
    assert_select 'textarea[name="follow_up[notes]"]', text: 'Keep this invalid date draft.'
    assert_select 'a[href=?]', reconciliation_follow_ups_path(queue), text: 'Back to selected queue'
    assert_equal 'Synthetic concurrent update.', item.reload.notes
  end

  test 'queue return accepts only validated local filters and tenant originals and does not grant readers progress controls' do
    item = ReconciliationFollowUp.create!(@values.merge(created_by: @user))
    other = Tenant.create!(name: 'Foreign queue original', subdomain: 'foreign-queue-original')
    foreign = Current.set(tenant: other) do
      ReconciliationEvidence.retain!(bytes: 'Synthetic private original', filename: 'foreign-queue.txt', source: 'bank', kind: 'bank_statement', from: '2026-10-01', to: '2026-10-31')
    end
    ['https://example.com', { day: 'bad-date' }, { original: foreign.id }].each do |queue|
      get reconciliation_follow_up_path(item, queue: queue)
      assert_response :success
      assert_select 'section[aria-label="Return to your selected follow-up queue"]', count: 0
      assert_select 'button[value="queue"]', count: 0
      refute_includes response.body, foreign.filename
    end
    @user.update!(role: 'reporting')
    get reconciliation_follow_up_path(item, queue: { status: 'evil', source: 'evil', owner: 'evil', url: 'https://example.com', page: 9, day: '2026-10-14' })
    assert_select 'a[href=?]', reconciliation_follow_ups_path(status: 'active', day: '2026-10-14'), text: 'Back to selected queue'
    assert_select 'button[value="queue"]', count: 0
    refute_includes response.body, 'https://example.com'
    assert_equal 1, item.events.count
  end

  test 'filtered priorities count every page and day navigation preserves the selected scope without writes' do
    travel_to Time.zone.parse('2026-10-16 12:00') do
      requests = 26.times.map do |number|
        ReconciliationFollowUp.create!(@values.merge(created_by: @user, title: "Scoped request #{number}", submission_key: SecureRandom.uuid))
      end
      ReconciliationFollowUp.create!(@values.merge(created_by: @user, source: 'other', title: 'Other source request', submission_key: SecureRandom.uuid))
      filters = { status: 'overdue', source: 'bank', owner: 'mine', category: 'missing_report', evidence: 'missing', day: '2026-10-14' }
      assert_no_enqueued_jobs do
        assert_no_difference ['ReconciliationFollowUpEvent.count', 'ActionMailer::Base.deliveries.size'] do
          get reconciliation_follow_ups_path(filters.merge(page: 2, unexpected: 'discard-me'))
        end
      end
      assert_response :success
      assert_select 'section[aria-label="Priorities in this filtered view"]' do
        assert_select 'article p.font-display', text: '26', count: 2
        assert_select 'a[href=?]', reconciliation_follow_up_path(requests.first, close_day: '2026-10-14', queue: filters, anchor: 'record-progress'), text: 'Work earliest due', count: 2
        assert_select 'a[href=?]', reconciliation_follow_ups_path(filters.merge(day: '2026-10-13')), text: 'Previous day'
        assert_select 'a[href=?]', reconciliation_follow_ups_path(filters.merge(day: '2026-10-15')), text: 'Next day'
        assert_select 'a[href=?]', reconciliation_follow_ups_path(filters.except(:day)), text: 'All dates with these filters'
        assert_select 'a[href=?]', cash_forecast_path(day: '2026-10-14')
      end
      assert_select 'form[role="search"]'
      get reconciliation_follow_ups_path(filters.merge(day: '2026-09-30'))
      assert_select 'section[aria-label="Priorities in this filtered view"] article p.font-display', text: '0', count: 2
      assert_includes response.body, 'Check the financial close for untracked missing reports'
    end
  end

  test 'filtered priorities honor closed status original coverage tenant and reader boundaries' do
    travel_to Time.zone.parse('2026-10-16 12:00') do
      item = ReconciliationFollowUp.create!(@values.merge(created_by: @user))
      doc = ReconciliationEvidence.retain!(bytes: 'Synthetic covered statement', filename: 'scoped-statement.txt', source: 'bank', kind: 'bank_statement', from: '2026-10-01', to: '2026-10-31')
      @user.update!(role: 'reporting')
      get reconciliation_follow_ups_path(original: doc.id, day: '2026-10-14')
      assert_select 'section[aria-label="Priorities in this filtered view"]' do
        assert_select 'a', text: 'Work earliest due', count: 0
        assert_select 'a', text: 'Review earliest due', count: 2
        assert_select 'a[href=?]', reconciliation_follow_ups_path(status: 'active', original: doc.id, day: '2026-10-15'), text: 'Next day'
      end
      item.update!(status: 'closed', notes: 'Synthetic reviewed exception.')
      get reconciliation_follow_ups_path(status: 'closed')
      assert_select 'section[aria-label="Priorities in this filtered view"] article p.font-display', text: '0', count: 2
      other = Tenant.create!(name: 'Separate queue', subdomain: 'separate-queue')
      @user.update!(tenant: other)
      get reconciliation_follow_ups_path
      assert_select 'section[aria-label="Priorities in this filtered view"] article p.font-display', text: '0', count: 2
      refute_includes response.body, item.title
      get reconciliation_follow_ups_path(original: doc.id)
      assert_response :not_found
    end
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
