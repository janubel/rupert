# frozen_string_literal: true

require 'test_helper'

class OperationsWorkspaceTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = Tenant.create!(name: 'Operations fixture', subdomain: 'operations-fixture')
    @user = User.create!(tenant: @tenant, email: 'operations@example.test', password: 'password123', role: 'admin')
    post login_path, params: { email: @user.email, password: 'password123' }
    Current.tenant = @tenant
    Finance::ChartOfAccounts.seed! # expenses post to the ledger, which needs the chart
  end
  teardown { Current.reset }

  test 'workspace pages and finance forms render with shared role-aware navigation' do
    [sales_path, inventory_index_path, inventory_counts_path, movements_inventory_index_path, reconcile_index_path,
     finance_accounts_path, finance_expenses_path, finance_vendor_payments_path, finance_chart_of_accounts_path,
     new_finance_expense_path, new_finance_vendor_payment_path, new_finance_chart_of_account_path,
     financial_close_path, daily_reconciliations_path, money_reconciliations_path, reconciliation_documents_path,
     reconciliation_follow_ups_path, overview_reconciliation_follow_ups_path, cash_forecast_path, ledger_index_path].each do |path|
      get path
      assert_response :success, path
      assert_select 'nav[aria-label="Module"]', minimum: 1
    end
    get new_finance_expense_path
    assert_select 'input[name="expense[amount]"][required][inputmode=decimal]'
    get new_finance_vendor_payment_path
    assert_select 'input[name="vendor_payment[amount]"][required]'
    get new_finance_chart_of_account_path
    assert_select 'input[name="account[code]"]'
    get financial_close_path, params: { day: '2026-10-10' }
    assert_select 'nav[aria-label="Module"] a[href=?]', daily_reconciliations_path
    assert_select 'nav[aria-label="Reconciliation workflow"]'
    assert_select '[aria-label="Close status overview"]'
  end

  test 'finance forms save exact dollars and retain invalid input without creating records' do
    attributes = { payee: 'Precision fixture', category: 'other', incurred_on: Date.current, amount: '0.29' }
    post finance_expenses_path, params: { expense: attributes }
    assert_redirected_to finance_expenses_path
    assert_equal 29, Finance::Expense.last.amount_cents
    ['1.001', '1e3', '-2', 'NaN', '', '21,474,836.47', '21474836.48'].each do |amount|
      assert_no_difference 'Finance::Expense.count' do
        post finance_expenses_path, params: { expense: attributes.merge(amount: amount) }
        assert_response :unprocessable_entity, amount
        assert_select '[role=alert]'
        assert_not_includes response.body, 'Amount cents'
        assert_select 'input[name="expense[payee]"][value="Precision fixture"]'
      end
    end
    vendor = Purchasing::Vendor.create!(name: 'Credit fixture')
    post finance_vendor_payments_path, params: { vendor_payment: { vendor_id: vendor.id, amount: '12.34', paid_on: Date.current } }
    assert_redirected_to finance_vendor_payments_path
    assert_equal 1234, Finance::VendorPayment.last.amount_cents
    get finance_accounts_path
    assert_select '[aria-label="Vendor balances"] tr', text: /Credit fixture.*\$12\.34/m
    assert_select '[aria-label="Vendor balance summary"]', text: /Vendor credits.*\$12\.34/m
    assert_select '[aria-label="Vendor balance summary"]', text: /Vendor balances due.*\$0\.00/m
    post finance_chart_of_accounts_path, params: { account: { code: '9910', name: 'UI fixture', account_type: 'expense', normal_balance: 'debit', active: '1' } }
    assert_redirected_to finance_chart_of_accounts_path
    assert Finance::Account.exists?(code: '9910')
  end

  test 'receivables never offset or combine different currencies' do
    customer = Core::Customer.create!(source: 'manual', external_id: 'currency-fixture', first_name: 'Currency Fixture')
    { 'USD' => [1000, 250], 'EUR' => [2000, 500] }.each do |currency, (gross, payment)|
      order = order!(source: 'manual', source_order_id: currency, currency: currency, gross_cents: gross, customer: customer, status: 'paid', occurred_at: Time.current)
      order.payments.create!(method: 'card', amount_cents: payment, status: 'completed', paid_at: Time.current)
    end
    balances = Core::Receivables.by_customer.to_h { |row| [row[:currency], row[:balance_cents]] }
    assert_equal({ 'USD' => 750, 'EUR' => 1500 }, balances)
    get finance_accounts_path
    assert_select '[aria-label="Customer receivables"] tr', text: /Currency Fixture.*USD.*\$7\.50/m
    assert_select '[aria-label="Customer receivables"] tr', text: /Currency Fixture.*EUR.*EUR 15.00/m
  end

  test 'missing order amounts keep receivables unknown' do
    customer = Core::Customer.create!(source: 'manual', external_id: 'unknown-fixture', first_name: 'Unknown Fixture')
    order!(source: 'manual', source_order_id: 'missing-gross', customer: customer, status: 'paid', currency: 'USD', gross_cents: nil, occurred_at: Time.current)
    assert_nil Core::Receivables.by_customer.first[:balance_cents]
    get finance_accounts_path
    assert_response :success
    assert_select '[aria-label="Customer receivables"] tr', text: /Unknown Fixture.*Unknown/m
  end

  test 'removed finance history stays visible but never enters active totals' do
    active = Finance::Expense.create!(payee: 'Active fixture', category: 'other', incurred_on: Date.current, amount_cents: 1000)
    removed = Finance::Expense.create!(payee: 'Removed fixture', category: 'other', incurred_on: Date.current, amount_cents: 9000)
    removed.discard!
    get finance_expenses_path, params: { include_deleted: '1' }
    assert_response :success
    assert_select '.stat-value', '$10.00'
    assert_select 'td', text: /Removed fixture/
    assert_includes response.body, 'Removed'
    get finance_expenses_path(format: :csv), params: { include_deleted: '1' }
    assert_includes response.body, removed.payee
    assert_includes response.body, active.payee
  end

  test 'selected sales date includes native C-Trax once and excludes cancelled and foreign totals' do
    day = Date.new(2026, 10, 10)
    at = day.in_time_zone.change(hour: 23)
    location = Location.create!(name: 'Late fixture', source: 'manual', externalId: 'late-fixture')
    order = order!(source: 'shopify', source_order_id: 'SALE-ONE', order_number: 'SALE-ONE', status: 'paid', gross_cents: 1000, currency: 'USD', occurred_at: at, location_id: location.externalId)
    order.payments.create!(method: 'card', amount_cents: 1000, status: 'completed', paid_at: at)
    order!(source: 'shopify', source_order_id: 'CANCELLED', status: 'cancelled', gross_cents: 9000, occurred_at: at)
    order!(source: 'shopify', source_order_id: 'FOREIGN', status: 'paid', gross_cents: 5000, currency: 'EUR', occurred_at: at)
    ctrax = Location.create!(source: 'ctrax', externalId: 'sales-ui/7', name: 'Retail fixture')
    CtraxDay.create!(location: ctrax, store_id: '7', business_date: day, currency: 'USD', timezone: Time.zone.name, api_origin: 'https://fixture.api.cannatrax.net', captured_at: Time.current, source_digest: 'fixture',
      orders_json: [{ 'id' => '41', 'status' => 'completed', 'deleted' => false, 'completed_at' => at.iso8601, 'total' => 2000, 'tip' => 500 }], sessions_json: [], controls_json: {})
    get sales_path, params: { date: day.iso8601, window: 7 }
    assert_response :success
    assert_select '[aria-label="Recorded sales summary"]', text: /Recorded sales.*USD 30.00.*Sales recorded.*2/m
    assert_select '[aria-label="Order journal"]', text: /EUR 50.00/m
    assert_select '[aria-label="Hourly sales by location"] tr', text: /11 PM.*USD 10.00/m
    assert_includes response.body, 'ending 2026-10-10'
    get sales_path, params: { date: day.iso8601, source: 'ctrax', window: 7 }
    assert_select '[aria-label="Recorded sales summary"]', text: /Recorded sales.*USD 20.00/m
    assert_select 'td.empty-row', text: /native C-Trax receipts/
  end

  test 'report readers see finance evidence links but cannot write finance or inventory records' do
    @user.update_permission_overrides!(%w[reports.read inventory.read reconcile.read])
    get financial_close_path
    assert_response :success
    assert_select 'nav[aria-label="Module"] a[href=?]', finance_accounts_path, count: 0
    assert_select '#retain-close', count: 0
    get stock_comparison_path
    assert_response :success
    assert_select 'nav[aria-label="Module areas"] a[aria-label=Stock][aria-current=page]'
    assert_select 'nav[aria-label="Module"] a[href=?]', inventory_counts_path
    assert_select 'a[href=?]', new_inventory_count_path, count: 0
    get reconcile_index_path
    assert_response :success
    assert_select 'form[action*=approve]', count: 0
    get finance_accounts_path
    assert_response :redirect
  end

  test 'inventory staff use stock workflows without financial actions' do
    @user.update!(role: 'inventory_employee')
    get inventory_counts_path
    assert_response :success
    assert_select 'nav[aria-label="Module areas"] a[aria-label=Stock][aria-current=page]'
    assert_select 'a[href=?]', new_inventory_count_path
    assert_select 'a[href=?]', finance_accounts_path, count: 0
    get finance_accounts_path
    assert_response :redirect
  end

  test 'ledger amounts stay grouped by source currency' do
    { 'USD' => 1000, 'EUR' => 2000 }.each do |currency, cents|
      LedgerEntry.create!(source: 'shopify', sourceOrderId: currency, orderName: "Ledger #{currency}", currency: currency, grossCents: cents, lineItems: 1, status: 'PAID', occurredAt: Time.current, syncedAt: Time.current)
    end
    get ledger_index_path
    assert_response :success
    assert_select '[aria-label="Ledger totals by currency"]', text: /USD 10.00/
    assert_select '[aria-label="Ledger totals by currency"]', text: /EUR 20.00/
    assert_not_includes response.body, 'USD 30.00'
  end

  private

  def order!(**attributes)
    status = attributes.delete(:status)
    order = Core::Order.create!(attributes)
    order.mark_paid! if status == 'paid'
    order.cancel! if status == 'cancelled'
    order
  end
end
