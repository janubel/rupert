# frozen_string_literal: true

require 'test_helper'

class MoneyReconciliationsTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = tenants(:default_tenant)
    post login_path, params: { email: users(:regular_user).email, password: 'password' }
  end

  teardown { Current.reset }

  test 'daily weekly monthly HTML JSON and CSV expose honest review state' do
    %w[daily weekly monthly].each do |kind|
      get money_reconciliations_path, params: { kind: kind, date: '2026-10-15' }
      assert_response :success
      assert_select 'h1', 'Source reports'
      assert_includes response.body, 'Review required'
      assert_select '[aria-label="Vendor source coverage"] [data-finance-source]', count: 4
      %w[ctrax square shopify swipesimple].each { |source| assert_select "[data-finance-source='#{source}'] h3", count: 1 }
      assert_includes response.body, 'Confirm coverage before treating this as zero activity.'
      assert_equal 'private, no-store', response.headers['Cache-Control']
    end
    get money_reconciliations_path(format: :csv), params: { kind: 'monthly', date: '2026-10-15' }
    assert_response :success
    assert_includes response.body, 'Source,Account,Currency'
    get money_reconciliations_path(format: :json), params: { kind: 'weekly', date: '2026-10-15' }
    assert_equal '2026-10-12', response.parsed_body['from']
    assert_equal '2026-10-18', response.parsed_body['to']
    refute_includes response.body, 'credentials_json'
  end

  test 'daily reconciliation displays all four vendors even without period observations' do
    get daily_reconciliations_path, params: { day: '2026-10-15' }
    assert_response :success
    assert_select '[aria-label="Vendor source coverage"] [data-finance-source]', count: 4
  end

  test 'earlier saved reports do not borrow current source coverage' do
    Current.tenant = @tenant
    report = MoneyReconciliationReport.new(date: '2026-10-15').save!
    report.update!(payload_json: report.payload.except('source_coverage').to_json)
    get money_reconciliations_path, params: { saved: report.id }
    assert_response :success
    assert_includes response.body, 'earlier saved review has no source-coverage summary'
    assert_select '[data-finance-source]', count: 0
  end

  test 'saving records an encrypted review without queuing external work' do
    assert_no_enqueued_jobs do
      assert_difference 'MoneyReconciliation.unscoped.count', 1 do
        post money_reconciliations_path, params: { kind: 'daily', date: '2026-10-15' }
      end
    end
    assert_response :redirect
    follow_redirect!
    assert_response :success
    assert_includes response.body, 'Saved source review'
  end

  test 'report readers can view but cannot save a review' do
    reader = User.create!(email: 'money-reader@example.invalid', password: 'password123', role: 'reader', tenant: @tenant)
    delete logout_path
    post login_path, params: { email: reader.email, password: 'password123' }
    get money_reconciliations_path
    assert_response :success
    assert_no_difference 'MoneyReconciliation.unscoped.count' do
      post money_reconciliations_path, params: { kind: 'daily', date: '2026-10-15' }
    end
    assert_response :redirect
  end

  test 'invalid dates and other tenant saved IDs cannot expose private reports' do
    get money_reconciliations_path, params: { date: 'wrong' }
    assert_redirected_to money_reconciliations_path
    Current.tenant = Tenant.create!(name: 'Other reports', subdomain: 'other-money-reports')
    saved = MoneyReconciliationReport.new(date: '2026-10-15').save!
    Current.reset
    get money_reconciliations_path, params: { saved: saved.id }
    assert_response :not_found
  end
end
