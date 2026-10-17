# frozen_string_literal: true

# Regression coverage for the October 17 integrity and privacy audit.
require 'test_helper'

class AuditIntegrityIntegrationTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
  end
  teardown { Current.reset }

  def login_admin
    post login_path, params: { email: 'admin@example.com', password: 'password' }
    assert_response :redirect
    Current.tenant = @tenant
  end

  test 'warehouse link must not expose an unrelated imported order' do
    share = WarehouseShare.create!(name: 'Synthetic vendor')
    Core::Order.create!(source: 'shopify', source_order_id: 'audit-order', order_number: 'AUDIT-1001',
      channel: 'web', currency: 'USD', gross_cents: 2500, occurred_at: Time.current,
      shipping_name: 'Synthetic Private Customer', shipping_address1: '123 Synthetic Private Lane', shipping_phone: '555-0100')
    Current.reset
    get warehouse_order_path(share.token, 'AUDIT-1001')
    assert_response :not_found
    refute_includes response.body, '123 Synthetic Private Lane'
  end

  test 'second expense edit must update the posted ledger amount' do
    login_admin
    post finance_expenses_path, params: { expense: { payee: 'Audit vendor', category: 'supplies', amount: '12.50', incurred_on: Date.current, method: 'cash' } }
    assert_response :redirect
    expense = Finance::Expense.last
    patch finance_expense_path(expense), params: { expense: { amount: '20.00' } }
    assert_response :redirect
    patch finance_expense_path(expense), params: { expense: { amount: '30.00' } }
    assert_response :redirect
    assert_equal 3000, expense.reload.amount_cents
    assert_equal 3000, Finance::JournalEntry.for_source('Finance::Expense', expense.id).posted.sole.debit_cents
  end

  test 'recording vendor payment must also post its journal entry' do
    login_admin
    vendor = Purchasing::Vendor.create!(name: 'Synthetic supplier')
    assert_difference 'Finance::JournalEntry.posted.count', 1 do
      post finance_vendor_payments_path, params: { vendor_payment: { vendor_id: vendor.id, amount: '25.00', paid_on: Date.current, method: 'bank_transfer' } }
      assert_response :redirect
      assert_equal 2500, Finance::VendorPayment.last.amount_cents
    end
  end

  test 'vendor payment removal and restoration track its current journal entry' do
    login_admin
    vendor = Purchasing::Vendor.create!(name: 'Synthetic supplier')
    post finance_vendor_payments_path, params: { vendor_payment: { vendor_id: vendor.id, amount: '25.00', paid_on: Date.current, method: 'bank_transfer' } }
    payment = Finance::VendorPayment.last
    delete finance_vendor_payment_path(payment)
    assert_equal 0, Finance::JournalEntry.for_source('Finance::VendorPayment', payment.id).posted.count
    post restore_finance_vendor_payment_path(payment)
    assert_equal 2500, Finance::JournalEntry.for_source('Finance::VendorPayment', payment.id).posted.sole.debit_cents
    delete finance_vendor_payment_path(payment)
    assert_equal 0, Finance::JournalEntry.for_source('Finance::VendorPayment', payment.id).posted.count
  end

  test 'vendor payment posting failure rolls back the payment' do
    login_admin
    vendor = Purchasing::Vendor.create!(name: 'Synthetic supplier')
    Finance::Posting.stubs(:vendor_payment).raises(Finance::Posting::Error, 'Synthetic posting failure')
    assert_no_difference 'Finance::VendorPayment.count' do
      post finance_vendor_payments_path, params: { vendor_payment: { vendor_id: vendor.id, amount: '25.00', paid_on: Date.current, method: 'bank_transfer' } }
    end
    assert_response :unprocessable_entity
  end
end

class AuditIntegrityServicesTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
  end
  teardown { Current.reset }

  test 'full biweekly salaried period must pay one twenty sixth of annual salary' do
    rate = stub(pay_type: 'salary', annual_salary_cents: 5_200_000, pay_frequency: 'biweekly')
    employee = stub(current_pay_rate: rate)
    run = stub(period_start: Date.new(2026, 1, 5), period_end: Date.new(2026, 1, 18))
    assert_equal 200_000, People::PayrollCalculator.send(:gross_for, employee, 0, 0, run)
  end

  test 'salary periods include the final day and calendar-month length' do
    rate = stub(pay_type: 'salary', annual_salary_cents: 6_240_000, pay_frequency: 'weekly')
    employee = stub(current_pay_rate: rate)
    week = stub(period_start: Date.new(2026, 1, 5), period_end: Date.new(2026, 1, 11))
    assert_equal 120_000, People::PayrollCalculator.send(:gross_for, employee, 0, 0, week)
    rate.stubs(:pay_frequency).returns('monthly')
    month = stub(period_start: Date.new(2028, 2, 1), period_end: Date.new(2028, 2, 29))
    assert_equal 520_000, People::PayrollCalculator.send(:gross_for, employee, 0, 0, month)
  end

  test 'split payments allocate the final sales tax rounding cent exactly once' do
    Finance::ChartOfAccounts.seed!
    order = Core::Order.create!(source: 'rupert_pos', source_order_id: 'audit-split-sale', order_number: 'AUDIT-SPLIT',
      channel: 'pos', currency: 'USD', gross_cents: 11_000, tax_cents: 1000, tip_cents: 2000, occurred_at: Time.current)
    [4350, 8650].each do |amount|
      payment = order.payments.create!(method: 'card', amount_cents: amount, status: 'completed', paid_at: Time.current)
      Finance::Posting.sale(payment)
    end
    tax_account = Finance::Account.find_by!(code: '2100')
    assert_equal 1000, Finance::JournalLine.where(account: tax_account).sum(:credit_cents)
  end

  test 'ignored bank lines must leave reconciliation totals and unmatched queue' do
    line = BankStatementLine.create!(document_id: 1, line_no: 1, account_label: 'Synthetic Checking',
      posted_on: Date.current, description: 'Synthetic duplicate', amount_cents: 1000, fingerprint: SecureRandom.hex(20))
    line.decide!(status: 'ignored', user: User.find_by!(email: 'admin@example.com'))
    report = Finance::BankReconciliation.new(account_label: 'Synthetic Checking', from: Date.current, to: Date.current)
    assert_equal 0, report.summary[:statement_net_cents]
    assert_equal 0, report.summary[:unmatched_lines]
  end

  test 'sale posting must not allocate tip receipts to collected sales tax' do
    Finance::ChartOfAccounts.seed!
    order = Core::Order.create!(source: 'rupert_pos', source_order_id: 'audit-tipped-sale', order_number: 'AUDIT-TIP',
      channel: 'pos', currency: 'USD', gross_cents: 11_000, tax_cents: 1000, tip_cents: 2000, occurred_at: Time.current)
    payment = order.payments.create!(method: 'card', amount_cents: 13_000, status: 'completed', paid_at: Time.current)
    entry = Finance::Posting.sale(payment)
    tax_account = Finance::Account.find_by!(code: '2100')
    assert_equal 1000, entry.journal_lines.find_by!(account_id: tax_account.id).credit_cents
  end

  test 'warehouse retry after approved charge and local failure must not issue another charge' do
    share = WarehouseShare.create!(name: 'Synthetic vendor', priceMultiplier: 1)
    product = ShopifyProduct.create!(id: 'audit-product', title: 'Synthetic product')
    variant = ShopifyVariant.create!(id: 'audit-variant', productId: product.id, title: 'Synthetic variant', sku: 'AUDIT-SKU', price: 10, tracked: true)
    InventoryLevel.create!(source: 'shopify', locationId: 'audit-location', shopifyVariantId: variant.id, quantity: 10, available: 10)
    cart = WarehouseCart.create!(tenant_id: Current.tenant_id, share_id: share.id, token: SecureRandom.hex(20), status: 'open')
    cart.add_item!(variant, quantity: 1)
    AuthorizeNetClient.stubs(:configured?).returns(true)
    gateway_calls = 0
    AuthorizeNetClient.stubs(:charge!).with { |**args|
      gateway_calls += 1
      true }.returns(
      AuthorizeNetClient::Result.new(transaction_id: 'synthetic-accepted-charge', response_code: '1', message: 'Approved'))
    Core::OrderLine.stubs(:create!).raises(ActiveRecord::RecordInvalid.new(Core::OrderLine.new))
    first = WarehouseCheckoutService.call(share: share, cart: cart, payment_nonce: 'synthetic-nonce-one')
    refute_predicate first, :success?
    assert_equal 1, gateway_calls
    assert_equal 0, Core::Order.count
    refute cart.reload.checked_out?
    Core::OrderLine.unstub(:create!)
    WarehouseCheckoutService.call(share: share, cart: cart.reload, payment_nonce: 'synthetic-nonce-two')
    assert_equal 1, gateway_calls, 'Approved external charge must remain durable and block an unreviewed retry'
  end

  test 'pre-restore SQLite recovery copy must include committed WAL rows' do
    require 'sqlite3'
    Dir.mktmpdir('rupert-audit-wal') do |dir|
      original = File.join(dir, 'live.sqlite3')
      upload = File.join(dir, 'upload.sqlite3')
      source = SQLite3::Database.new(original)
      source.execute('PRAGMA journal_mode=WAL')
      source.execute('PRAGMA wal_autocheckpoint=0')
      source.execute('CREATE TABLE audit_rows (id INTEGER PRIMARY KEY)')
      source.execute('INSERT INTO audit_rows VALUES (1)')
      source.execute('PRAGMA wal_checkpoint(TRUNCATE)')
      source.execute('INSERT INTO audit_rows VALUES (2)')
      uploaded = SQLite3::Database.new(upload)
      uploaded.execute('CREATE TABLE upload_rows (id INTEGER PRIMARY KEY)')
      uploaded.close
      assert_equal 2, source.get_first_value('SELECT count(*) FROM audit_rows')
      BackupService.stub(:database_path, original) do
        assert_raises(BackupService::RestoreError) { BackupService.restore!(upload) }
      end
      refute File.exist?("#{original}.pre-restore")
      assert_equal 2, source.get_first_value('SELECT count(*) FROM audit_rows')
      source.close
    end
  end
end
