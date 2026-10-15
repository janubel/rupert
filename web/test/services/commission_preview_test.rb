# frozen_string_literal: true

require 'test_helper'

class CommissionPreviewTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
    @user = users(:regular_user)
    @worker = People::Employee.create!(user: @user, first_name: 'First', last_name: 'Worker', employment_type: 'contractor')
    @second_user = User.create!(tenant: Current.tenant, email: 'second-commission@example.com', role: 'cashier', password: 'password')
    @second = People::Employee.create!(user: @second_user, first_name: 'Second', last_name: 'Worker', employment_type: 'part_time')
    shift(@worker, @user, '09:00', '12:00')
    shift(@second, @second_user, '10:00', '11:00')
  end

  teardown { Current.reset }

  test 'each overlapping worker receives full 1 percent with half-open boundaries' do
    sale('09:00')
    sale('10:00')
    sale('11:00')
    sale('12:00')
    result = preview
    first = result.rows.find { |row| row[:employee] == @worker.name }
    second = result.rows.find { |row| row[:employee] == @second.name }
    assert_equal 300, first[:commission_cents]
    assert_equal 100, second[:commission_cents]
    assert_equal 3, first[:order_count]
    assert_equal 1, second[:order_count]
    assert_equal 4, result.eligible_orders
  end

  test 'preview excludes unpaid voided refunded wrong-source and wrong-currency sales' do
    sale('10:30')
    sale('10:30', status: 'placed')
    sale('10:30', status: 'cancelled')
    sale('10:30', source: 'square')
    sale('10:30', currency: 'CAD')
    unpaid = sale('10:30')
    unpaid.payments.delete_all
    refund = sale('10:30')
    refund.refunds.create!(amount_cents: 100, refunded_at: Time.current, method: 'card')
    result = preview
    assert_equal 1, result.eligible_orders
    assert_equal 2, result.excluded_orders
    assert_equal [100, 100], result.rows.map { |row| row[:commission_cents] }
  end

  test 'item price basis excludes gross tax and rounds each order half up' do
    order = sale('10:30', base: 50, gross: 1050)
    result = preview
    assert_equal [50, 50], result.rows.map { |row| row[:sales_cents] }
    assert_equal [1, 1], result.rows.map { |row| row[:commission_cents] }
    assert_equal 1050, order.gross_cents
  end

  test 'approved correction changes preview without creating payroll records' do
    sale('09:30')
    before = preview.rows.find { |row| row[:employee] == @second.name }
    assert_equal 0, before[:commission_cents]
    correction = TimeClockService.request_correction(user: @second_user, shift_id: ClockShift.find_by(employee: @second).id,
      attributes: { proposed_started_at: Time.zone.parse('2026-10-10 09:00'), proposed_ended_at: Time.zone.parse('2026-10-10 11:00'), reason: 'Clock-in correction' })
    assert_no_difference -> { People::Payslip.count + People::Timesheet.count } do
      TimeClockService.review(correction: correction, reviewer: @user, approve: true)
    end
    after = preview.rows.find { |row| row[:employee] == @second.name }
    assert_equal 100, after[:commission_cents]
  end

  test 'tenant context excludes foreign shifts and sales' do
    sale('10:30')
    other = Tenant.create!(name: 'Private commission tenant', subdomain: 'private-commission')
    Current.tenant = other
    assert_empty preview.rows
    assert_equal 0, preview.eligible_orders
  end

  test 'mixed valid and unknown item prices exclude the entire order' do
    order = sale('10:30')
    order.order_lines.create!(name: 'Unknown unit price', unit_cents: 0, line_cents: 2000, quantity: 1)
    assert_equal 0, preview.eligible_orders
    assert_equal 1, preview.excluded_orders
    order.order_lines.last.update_columns(unit_cents: nil)
    assert_equal 0, preview.eligible_orders
  end

  test 'cached shifts and correction requests cannot be reviewed in another tenant' do
    shift = ClockShift.find_by(employee: @worker)
    correction = TimeClockService.request_correction(user: @user, shift_id: shift.id,
      attributes: { proposed_started_at: Time.zone.parse('2026-10-10 08:00'), proposed_ended_at: Time.zone.parse('2026-10-10 09:00'), reason: 'Remote correction' })
    Current.tenant = Tenant.create!(name: 'Other clock context', subdomain: 'other-clock-context')
    assert_raises(ActiveRecord::RecordNotFound) { shift.serialize_change { shift.update!(ended_at: Time.current) } }
    assert_raises(ActiveRecord::RecordNotFound) { TimeClockService.review(correction: correction, reviewer: @user, approve: true) }
  end

  private

  def preview
    CommissionPreview.new(start_date: '2026-10-10', end_date: '2026-10-10', source: 'shopify', currency: 'USD')
  end

  def shift(worker, user, started, ended)
    ClockShift.create!(user: user, employee: worker, employee_key: worker.id.to_s, employee_name: worker.name,
      employment_type: worker.employment_type, started_at: Time.zone.parse("2026-10-10 #{started}"),
      ended_at: Time.zone.parse("2026-10-10 #{ended}"), request_token: SecureRandom.uuid)
  end

  def sale(time, base: 10_000, gross: 11_000, status: 'paid', source: 'shopify', currency: 'USD')
    order = Core::Order.new(source: source, source_order_id: SecureRandom.uuid, occurred_at: Time.zone.parse("2026-10-10 #{time}"),
      gross_cents: gross, tax_cents: gross - base, currency: currency)
    order.aasm.current_state = status.to_sym
    order.save!
    order.order_lines.create!(name: 'Merchandise', unit_cents: base, quantity: 1, line_cents: base)
    order.payments.create!(method: 'card', amount_cents: gross, status: 'completed', paid_at: order.occurred_at)
    order
  end
end
