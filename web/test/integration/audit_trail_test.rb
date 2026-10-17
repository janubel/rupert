# frozen_string_literal: true

require 'test_helper'

class AuditTrailTest < ActionDispatch::IntegrationTest
  setup do
    Current.tenant = tenants(:default_tenant)
    @tenant = Current.tenant
    post login_path, params: { email: 'admin@example.com', password: 'password' }
  end

  teardown { Current.tenant = nil }

  def last_entry(action)
    ActivityLog.where(tenant_id: @tenant.id, action: action).order(:id).last
  end

  test 'business settings changes are recorded without values' do
    post tenant_settings_path, params: { business_name: 'Renamed Co', low_stock_threshold: '3' }
    entry = last_entry('business_settings_saved')
    assert entry
    assert_equal 'business_name, low_stock_threshold', entry.details
    assert_nil entry.subject_type
  end

  test 'a wrong password on secret export is recorded as denied' do
    User.find_by!(email: 'admin@example.com').update_columns(role: 'super_admin')
    post env_export_settings_path, params: { password: 'wrong' }
    assert last_entry('settings_env_export_denied')
  end

  test 'issuing and revoking an API token is recorded and never stores the secret' do
    post api_access_tokens_path, params: { api_access_token: { name: 'Audit probe', scopes: ['inventory:read'] } }
    entry = last_entry('api_token_issued')
    assert entry
    assert_includes entry.details, 'inventory:read'
    assert_not_includes entry.details.to_s, 'rupert_'
    post revoke_api_access_token_path(ApiAccessToken.order(:id).last)
    assert last_entry('api_token_revoked')
  end

  test 'adding a location is recorded' do
    post locations_path, params: { location: { name: 'Audit Shop', kind: 'store', timezone: 'America/New_York', active: '1' } }
    assert last_entry('location_added')
  end

  test 'activity page filters by group, search and date and exports csv' do
    ActivityLogger.log('daily_reconciliation_reviewed', details: '2026-10-15: reviewed')
    ActivityLogger.log('location_added', details: 'x')
    ActivityLogger.log('expense_updated', details: '=HYPERLINK("http://x")')

    get activity_path(group: 'money')
    assert_response :success
    assert_includes response.body, 'daily reconciliation reviewed'
    assert_not_includes response.body, 'location added'

    get activity_path(q: 'HYPERLINK')
    assert_includes response.body, 'expense updated'
    assert_not_includes response.body, 'daily reconciliation reviewed'

    get activity_path(from: (Date.current + 1).iso8601)
    assert_includes response.body, 'No matching activity'

    get activity_path(format: :csv)
    assert_response :success
    assert_equal 'text/csv', response.media_type
    assert_includes response.body, "'=HYPERLINK"
    assert_equal 'private, no-store', response.headers['Cache-Control']
  end

  test 'audit trails outlive the mirrors' do
    assert_operator DataRetention::POLICIES['ActivityLog'].first, :>=, 2000.days
    assert_operator DataRetention::POLICIES['AccessLog'].first, :>=, 365.days
  end

  test 'reconciliation review and archive are recorded in the activity trail' do
    day = '2026-10-14'
    post archive_daily_reconciliations_path, params: { day: day }
    assert last_entry('daily_report_archived')
    digest = DailyMoneyReconciliation.new(day: day).digest
    post review_daily_reconciliations_path, params: { day: day, report_digest: digest, status: 'reviewed', notes: 'Checked.' }
    entry = last_entry('daily_reconciliation_reviewed')
    assert entry
    assert_equal "#{day}: reviewed", entry.details
    assert_equal 'DailyReconciliationReview', entry.subject_type
  end
end
