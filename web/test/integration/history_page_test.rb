# frozen_string_literal: true

require 'test_helper'

class HistoryPageTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    Finance::ChartOfAccounts.seed!
    post login_path, params: { email: 'admin@example.com', password: 'password' }
  end

  teardown { Current.reset }

  test 'shows every source with coverage honesty and no raw rows' do
    BankStatementLine.create!(document_id: 1, account_label: 'Operating', line_no: 1, posted_on: Date.new(2024, 1, 10), description: 'SECRET PAYEE', amount_cents: -987_654, fingerprint: 'x')
    get finance_history_path
    assert_response :success
    %w[QuickBooks Shopify Square C-Trax SwipeSimple NAB Authorize.net Bank\ statements Rupert\ ledger].each { |label| assert_includes response.body, label }
    assert_includes response.body, 'not</strong> when the business began'
    assert_includes response.body, '2024-01-10'
    assert_not_includes response.body, 'SECRET PAYEE'
    assert_not_includes response.body, '9,876.54'
  end

  test 'is permission gated to finance readers' do
    reader = User.create!(tenant: @tenant, role: 'cashier', email: 'cashier@example.com', password: 'password123')
    delete logout_path
    post login_path, params: { email: 'cashier@example.com', password: 'password123' }
    get finance_history_path
    assert_response :redirect
    assert_match(/permission/, flash[:alert])
    assert reader
  end

  test 'appears in the Bookkeeping tools menu' do
    get finance_quickbooks_imports_path
    assert_includes response.body, finance_history_path
  end
end
