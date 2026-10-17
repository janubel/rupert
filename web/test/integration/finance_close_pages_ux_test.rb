# frozen_string_literal: true

require 'test_helper'

# Daily-close pages share one header and offer one obvious primary action.
class FinanceClosePagesUxTest < ActionDispatch::IntegrationTest
  setup do
    Current.tenant = tenants(:default_tenant)
    post login_path, params: { email: 'admin@example.com', password: 'password' }
  end

  teardown { Current.reset }

  test 'each page uses the shared header with one primary action in it' do
    day = Date.new(2026, 10, 10).iso8601
    { 'Daily reconciliation' => daily_reconciliations_path(day: day),
      'Day close' => financial_close_path(day: day),
      'Report requests & follow-ups' => reconciliation_follow_ups_path,
      'Source documents' => reconciliation_documents_path }.each do |title, path|
      get path
      assert_response :success, path
      assert_select '.finance-header h1', title
      assert_select '.finance-header p.text-base', minimum: 1
      assert_select '.finance-header a.btn-primary', minimum: 0, maximum: 1
    end
  end

  test 'the selected follow-up category is a state, not a second primary button' do
    get reconciliation_follow_ups_path(category: 'missing_report')
    assert_select 'nav[aria-label="Follow-up purpose"] a.nav-pill-active[aria-current=page]', 'Missing reports'
    assert_select 'nav[aria-label="Follow-up purpose"] a.btn-primary', 0
  end
end
