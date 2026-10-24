# frozen_string_literal: true

require 'test_helper'

class TaxPayeesTest < ActionDispatch::IntegrationTest
  setup do
    Current.tenant = tenants(:default_tenant)
    @admin = users(:regular_user)
    @vendor = Purchasing::Vendor.create!(name: 'Leaf Lawyers LLP')
  end

  teardown { Current.reset }

  def payee(**attributes)
    Finance::TaxPayee.create!({ payee_key: "v:#{@vendor.id}", legal_name: 'Leaf Lawyers LLP', tax_classification: 'partnership',
      form_type: 'misc', misc_box: '10', tin_type: 'ein', tin: '12-3456789' }.merge(attributes))
  end

  test 'the TIN is encrypted, normalized to digits and shown only as its last four' do
    record = payee
    assert_equal '123456789', record.reload.tin
    assert_equal '6789', record.tin_last4
    assert_equal '•••-••-6789', record.masked_tin
    raw = ActiveRecord::Base.connection.select_value("SELECT tin FROM tax_payees WHERE id = #{record.id}")
    refute_includes raw.to_s, '123456789'
  end

  test 'form rules: MISC needs a box, TIN needs 9 digits and a type, corporations are flagged exempt except attorney fees' do
    refute Finance::TaxPayee.new(payee_key: 'p:sam', legal_name: 'Sam', tax_classification: 'individual', form_type: 'misc').valid?
    refute Finance::TaxPayee.new(payee_key: 'p:sam', legal_name: 'Sam', tax_classification: 'individual', form_type: 'nec', tin: '123').valid?
    refute Finance::TaxPayee.new(payee_key: 'p:sam', legal_name: 'Sam', tax_classification: 'individual', form_type: 'nec', tin: '123456789').valid?
    refute Finance::TaxPayee.new(payee_key: 'x:1', legal_name: 'Sam', tax_classification: 'individual', form_type: 'nec').valid?
    nec = Finance::TaxPayee.new(payee_key: 'p:corp', legal_name: 'Corp', tax_classification: 'c_corporation', form_type: 'nec')
    assert nec.likely_exempt?
    refute payee(tax_classification: 'c_corporation').likely_exempt?
    assert_equal %w[W-9 address], payee(payee_key: 'p:other').missing
  end

  test 'admins add and edit payees without the TIN ever reaching the page; blank keeps it' do
    post login_path, params: { email: @admin.email, password: 'password' }
    get new_finance_tax_payee_path
    assert_response :success
    assert_select "option[value='v:#{@vendor.id}']", 'Leaf Lawyers LLP'
    post finance_tax_payees_path, params: { tax_payee: { payee_key: "v:#{@vendor.id}", legal_name: 'Leaf Lawyers LLP', tax_classification: 'partnership',
      form_type: 'misc', misc_box: '10', tin_type: 'ein', tin: '98-7654321', state: 'ny', postal_code: '10001' } }
    assert_redirected_to finance_tax_payees_path
    follow_redirect!
    assert_includes response.body, '•••-••-4321'
    refute_includes response.body, '987654321'
    record = Finance::TaxPayee.last
    assert_equal 'NY', record.state

    get edit_finance_tax_payee_path(record)
    refute_includes response.body, '987654321'
    patch finance_tax_payee_path(record), params: { tax_payee: { legal_name: 'Leaf Lawyers', tin: '' } }
    assert_equal ['Leaf Lawyers', '987654321'], [record.reload.legal_name, record.tin]
    get new_finance_tax_payee_path
    assert_select "option[value='v:#{@vendor.id}']", count: 0
  end

  test 'yearly totals leave out card payments, count paid contractor payslips, and apply the year threshold' do
    lawyer = payee
    Finance::VendorPayment.create!(vendor: @vendor, amount_cents: 1_500_00, paid_on: Date.new(2026, 3, 1), method: 'check')
    Finance::Expense.create!(vendor_id: @vendor.id, amount_cents: 700_00, incurred_on: Date.new(2026, 4, 1), method: 'other', category: 'other')
    Finance::Expense.create!(vendor_id: @vendor.id, amount_cents: 900_00, incurred_on: Date.new(2026, 5, 1), method: 'card', category: 'other')
    Finance::VendorPayment.create!(vendor: @vendor, amount_cents: 5_000_00, paid_on: Date.new(2025, 12, 31), method: 'check')
    cleaner = Finance::TaxPayee.create!(payee_key: 'p:sparkle cleaning', legal_name: 'Sam Sparkle', tax_classification: 'individual', form_type: 'nec')
    Finance::Expense.create!(payee: ' Sparkle Cleaning ', amount_cents: 650_00, incurred_on: Date.new(2026, 6, 1), method: 'cash', category: 'other')

    totals = Finance::Form1099Totals.new(year: 2026)
    row = totals.rows.find { |candidate| candidate.payee == lawyer }
    assert_equal [2_200_00, 900_00, 700_00, 2], [row.paid_cents, row.card_cents, row.other_method_cents, row.count]
    assert_equal 'needed', row.status(2026)
    small = totals.rows.find { |candidate| candidate.payee == cleaner }
    assert_equal [650_00, 'under'], [small.paid_cents, small.status(2026)]
    assert_equal 'needed', Finance::Form1099Totals.new(year: 2025).rows.find { |candidate| candidate.payee == lawyer }.status(2025)
    assert_equal 600_00, Finance::Form1099Totals.threshold_cents(2025, cleaner)

    post login_path, params: { email: @admin.email, password: 'password' }
    get finance_tax_payees_path(year: 2026)
    assert_response :success
    assert_includes response.body, 'Needs a 1099'
    get finance_tax_payees_path(year: 2026, format: :csv)
    assert_includes response.body, '2200.00'
    assert_includes response.body, '•••-••-6789'
    refute_includes response.body, '123456789'
  end

  test 'managers and cashiers cannot open 1099 payees' do
    payee
    %w[manager cashier].each do |role|
      user = User.create!(tenant: Current.tenant, email: "tax-#{role}@example.com", role: role, password: 'password123')
      post login_path, params: { email: user.email, password: 'password123' }
      get finance_tax_payees_path
      assert_includes [302, 303, 403], response.status, role
      delete logout_path
    end
  end
end
