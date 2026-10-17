# frozen_string_literal: true

require 'test_helper'

class BankStatementsIntegrationTest < ActionDispatch::IntegrationTest
  CSV_TEXT = "Date,Description,Amount\n2026-10-14,UPS STORE 123,-42.10\n2026-10-14,CARD DEPOSIT,500.00\n2026-10-15,ACME SUPPLY,-120.00\n"

  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    @vendor = Purchasing::Vendor.create!(name: 'Acme Supply')
    post login_path, params: { email: 'admin@example.com', password: 'password' }
  end

  teardown { Current.reset }

  def upload(csv = CSV_TEXT, label: 'Operating checking')
    file = Rack::Test::UploadedFile.new(StringIO.new(csv), 'text/csv', original_filename: 'oct.csv')
    post bank_statements_path, params: { account_label: label, file: file }
  end

  def last_entry(action) = ActivityLog.where(tenant_id: @tenant.id, action: action).order(:id).last

  test 'upload reads lines, retains the original and logs it' do
    upload
    doc = ReconciliationDocument.where(kind: 'bank_statement').last
    assert_redirected_to bank_statement_path(doc.id)
    assert_equal 3, BankStatementLine.pending.count
    assert last_entry('bank_statement_uploaded')
    follow_redirect!
    assert_includes response.body, 'UPS STORE 123'
    assert_includes response.body, 'Suggestion: Shipping'
  end

  test 'a bad file shows the reason and creates nothing' do
    upload("Date,Description,Amount\nnope,X,1\n")
    assert_response :unprocessable_entity
    assert_includes response.body, 'Could not read the date'
    assert_equal 0, BankStatementLine.count
  end

  test 'nothing is recorded until a person decides, then it records who and logs each' do
    upload
    assert_equal 0, Finance::Expense.count
    doc = ReconciliationDocument.where(kind: 'bank_statement').last
    ups, deposit, acme = BankStatementLine.for_document(doc.id).to_a
    post decide_bank_statement_path(doc.id), params: { decisions: { ups.id => 'expense:shipping', deposit.id => 'ignore', acme.id => "payment:#{@vendor.id}" } }
    assert_equal 4210, Finance::Expense.last.amount_cents
    assert_equal 'shipping', Finance::Expense.last.category
    assert_equal 12_000, Finance::VendorPayment.last.amount_cents
    assert_equal @vendor.id, Finance::VendorPayment.last.vendor_id
    assert_equal %w[recorded ignored recorded], BankStatementLine.for_document(doc.id).map(&:status)
    assert_equal users(:regular_user).id, ups.reload.decided_by_id
    assert last_entry('bank_statement_decided')
    # deciding again changes nothing
    assert_no_difference ['Finance::Expense.count', 'Finance::VendorPayment.count'] do
      post decide_bank_statement_path(doc.id), params: { decisions: { ups.id => 'expense:shipping' } }
    end
  end

  test 'a deposit cannot be recorded as an expense' do
    upload
    doc = ReconciliationDocument.where(kind: 'bank_statement').last
    deposit = BankStatementLine.for_document(doc.id).second
    post decide_bank_statement_path(doc.id), params: { decisions: { deposit.id => 'expense:other' } }
    assert_equal 0, Finance::Expense.count
    assert_equal 'pending', deposit.reload.status
  end

  test 'roles without finance access cannot view, upload or decide' do
    upload
    doc = ReconciliationDocument.where(kind: 'bank_statement').last
    line = BankStatementLine.for_document(doc.id).first
    users(:regular_user).update!(role: 'reporting')
    get bank_statements_path
    assert_redirected_to root_path
    get bank_statement_path(doc.id)
    assert_redirected_to root_path
    assert_no_difference ['BankStatementLine.count', 'Finance::Expense.count'] do
      upload(CSV_TEXT.sub('UPS', 'USPS'))
      post decide_bank_statement_path(doc.id), params: { decisions: { line.id => 'expense:shipping' } }
    end
  end
end
