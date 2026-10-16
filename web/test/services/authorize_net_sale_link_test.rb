# frozen_string_literal: true

require 'test_helper'

class AuthorizeNetSaleLinkTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
    @user = users(:regular_user)
    @order = Core::Order.create!(source: 'shopify', source_order_id: 'synthetic-linked-order', order_number: '#SYNTHETIC',
      occurred_at: Time.zone.parse('2026-10-10 10:00'), gross_cents: 11000, currency: 'USD')
    @order.mark_paid!
    @order.order_lines.create!(name: 'Item', quantity: 1, unit_cents: 10000, line_cents: 10000)
    @order.payments.create!(method: 'card', amount_cents: 11000, paid_at: @order.occurred_at)
    @employee = People::Employee.create!(user: @user, first_name: 'Shift', last_name: 'Worker')
    ClockShift.create!(user: @user, employee: @employee, employee_key: @employee.id.to_s, employee_name: @employee.name,
      employment_type: @employee.employment_type, started_at: Time.zone.parse('2026-10-10 09:00'),
      ended_at: Time.zone.parse('2026-10-10 11:00'), request_token: SecureRandom.uuid)
    @payment = AuthorizeNetTransaction.create!(environment: 'production', gateway_id: '12345', source_transaction_id: '9001',
      transaction_type: 'authCaptureTransaction', payment_status: 'capturedPendingSettlement', submitted_at: @order.occurred_at,
      currency: 'USD', authorized_amount: '110', settled_amount: '110', observed_at: Time.current, invoice_number: '#SYNTHETIC')
  end
  teardown { Current.reset }

  test 'reviewed link supplies payment proof once without new sales or tenders' do
    @order.payments.delete_all
    assert_equal 0, preview.eligible_orders
    assert_no_difference -> { Core::Order.count + Core::Payment.count } do
      match
      2.times { assert_equal 100, preview.rows.first[:commission_cents] }
    end
    assert_equal 1, preview.eligible_orders
  end

  test 'gateway void removes commission despite previously completed canonical tender' do
    match
    assert_equal 100, preview.rows.first[:commission_cents]
    @payment.update!(payment_status: 'voided')
    assert_equal 0, preview.rows.first[:commission_cents]
    assert_equal 1, preview.excluded_orders
  end

  test 'referenced refund removes commission and voided refund does not' do
    match
    refund = AuthorizeNetTransaction.create!(@payment.attributes.except('id', 'created_at', 'updated_at').merge(
      source_transaction_id: '9002', reference_transaction_id: '9001', transaction_type: 'refundTransaction',
      payment_status: 'refundPendingSettlement', authorized_amount: '1', settled_amount: '1'))
    assert_equal 0, preview.eligible_orders
    refund.update!(payment_status: 'voided')
    assert_equal 1, preview.eligible_orders
  end

  test 'same refund ID in another gateway cannot affect linked sale' do
    match
    AuthorizeNetTransaction.create!(@payment.attributes.except('id', 'created_at', 'updated_at').merge(
      gateway_id: '67890', source_transaction_id: '9002', reference_transaction_id: '9001',
      transaction_type: 'refundTransaction', payment_status: 'refundSettledSuccessfully'))
    assert_equal 1, preview.eligible_orders
  end

  test 'mismatch sandbox authorization-only and partial payments cannot be matched' do
    [{ environment: 'sandbox' }, { currency: 'CAD' }, { authorized_amount: '109.99' },
      { transaction_type: 'authOnlyTransaction' }, { payment_status: 'declined' }].each do |changes|
      original = @payment.attributes
      @payment.update!(changes)
      assert_raises(ActiveRecord::RecordInvalid) { match }
      @payment.update!(original.except('id', 'created_at', 'updated_at'))
    end
  end

  test 'unique active matches and retained revocation prevent duplicate commissions' do
    link = match
    assert_raises(ActiveRecord::RecordNotUnique) { match }
    link.update!(revoked_at: Time.current, revoked_by: @user)
    assert_equal 1, preview.eligible_orders
    replacement = match
    assert_equal 2, AuthorizeNetSaleLink.count
    assert_equal 1, AuthorizeNetSaleLink.active.count
    assert_equal 100, preview.rows.first[:commission_cents]
    assert_not replacement.destroy
  end

  test 'tenant context cannot approve a foreign sale or payment' do
    Current.tenant = Tenant.create!(name: 'Other matching workspace', subdomain: 'other-matching')
    assert_raises(ActiveRecord::RecordInvalid) { match }
    assert_empty AuthorizeNetSaleLink.active
  end

  test 'invoice and review notes remain encrypted in database columns' do
    link = match
    raw = AuthorizeNetTransaction.connection.select_value("SELECT invoice_number FROM authorize_net_transactions WHERE id = #{@payment.id}")
    refute_includes raw, '#SYNTHETIC'
    note = AuthorizeNetSaleLink.connection.select_value("SELECT evidence_note FROM authorize_net_sale_links WHERE id = #{link.id}")
    refute_includes note, 'Both source receipts'
  end

  private

  def match
    AuthorizeNetSaleLink.create!(authorize_net_transaction: @payment, order: @order, reviewed_by: @user,
      evidence_note: 'Both source receipts confirm this exact sale.')
  end

  def preview
    CommissionPreview.new(start_date: '2026-10-10', end_date: '2026-10-10', source: 'shopify', currency: 'USD')
  end
end
