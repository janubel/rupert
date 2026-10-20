# frozen_string_literal: true

require 'test_helper'

class EmployeePayWeekTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
    @user = users(:regular_user)
    @worker = People::Employee.create!(user: @user, first_name: 'First', last_name: 'Worker', employment_type: 'part_time')
    @second_user = User.create!(tenant: Current.tenant, email: 'second-pay-week@example.com', role: 'cashier', password: 'password')
    @second = People::Employee.create!(user: @second_user, first_name: 'Second', last_name: 'Worker', employment_type: 'part_time')
    People::PayRate.create!(employee: @worker, pay_type: 'hourly', hourly_rate_cents: 2000, effective_on: '2026-01-01')
    shift(@worker, @user, '09:00', '12:00')
    shift(@second, @second_user, '10:00', '11:00')
  end

  teardown { Current.reset }

  test 'weeks run Thursday to Wednesday' do
    assert_equal Date.new(2026, 10, 8), EmployeePayWeek.week_start(Date.new(2026, 10, 14))
    assert_equal Date.new(2026, 10, 15), EmployeePayWeek.week_start(Date.new(2026, 10, 15))
    pay = EmployeePayWeek.new(employee: @worker, week_of: Date.new(2026, 10, 10))
    assert_equal [Date.new(2026, 10, 8), Date.new(2026, 10, 14)], [pay.start_date, pay.end_date]
  end

  test 'shows hours, rate, base pay, commission and a shared tip for the chosen week' do
    sale('10:30', tip: 600)
    pay = EmployeePayWeek.new(employee: @worker, week_of: Date.new(2026, 10, 10))
    assert_in_delta 3.0, pay.hours, 0.001
    assert_equal 2000, pay.hourly_rate_cents
    assert_equal 6000, pay.base_cents
    assert_equal 100, pay.commission_cents
    assert_equal 300, pay.tip_cents
    assert_equal 6400, pay.total_cents
  end

  test 'a different week has no hours or sales' do
    sale('10:30')
    pay = EmployeePayWeek.new(employee: @worker, week_of: Date.new(2026, 10, 17))
    assert_equal 0, pay.hours
    assert_equal 0, pay.commission_cents
  end

  test 'base pay is unavailable without a pay rate' do
    pay = EmployeePayWeek.new(employee: @second, week_of: Date.new(2026, 10, 10))
    assert_nil pay.base_cents
    assert_includes pay.notes.join, 'No pay rate'
  end

  private

  def shift(worker, user, started, ended)
    ClockShift.create!(user: user, employee: worker, employee_key: worker.id.to_s, employee_name: worker.name,
      employment_type: worker.employment_type, started_at: Time.zone.parse("2026-10-10 #{started}"),
      ended_at: Time.zone.parse("2026-10-10 #{ended}"), request_token: SecureRandom.uuid)
  end

  def sale(time, tip: 0)
    order = Core::Order.new(source: 'shopify', source_order_id: SecureRandom.uuid, occurred_at: Time.zone.parse("2026-10-10 #{time}"),
      gross_cents: 11_000, tax_cents: 1000, tip_cents: tip, currency: 'USD')
    order.aasm.current_state = :paid
    order.save!
    order.order_lines.create!(name: 'Merchandise', unit_cents: 10_000, quantity: 1, line_cents: 10_000)
    order.payments.create!(method: 'card', amount_cents: 11_000, status: 'completed', paid_at: order.occurred_at)
  end
end
