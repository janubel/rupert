# frozen_string_literal: true

require 'test_helper'

class IncentiveModelTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
    @user = users(:regular_user)
    @worker = People::Employee.create!(user: @user, first_name: 'First', last_name: 'Worker', employment_type: 'part_time')
    ClockShift.create!(user: @user, employee: @worker, employee_key: @worker.id.to_s, employee_name: @worker.name,
      employment_type: @worker.employment_type, started_at: Time.zone.parse('2026-10-10 09:00'),
      ended_at: Time.zone.parse('2026-10-10 12:00'), request_token: SecureRandom.uuid)
    order = Core::Order.new(source: 'shopify', source_order_id: SecureRandom.uuid, occurred_at: Time.zone.parse('2026-10-10 10:30'),
      gross_cents: 11_000, tax_cents: 1000, tip_cents: 0, currency: 'USD')
    order.aasm.current_state = :paid
    order.save!
    order.order_lines.create!(name: 'Merchandise', unit_cents: 10_000, quantity: 1, line_cents: 10_000)
    order.payments.create!(method: 'card', amount_cents: 11_000, status: 'completed', paid_at: order.occurred_at)
  end

  teardown { Current.reset }

  def model(**plan)
    IncentiveModel.new(plan: IncentiveModel.plan_from(plan), period: 'custom', from: '2026-10-08', to: '2026-10-14',
      today: Date.new(2026, 10, 20))
  end

  test 'today\'s rule matches the Pay tab and the plan uses its own rate' do
    row = model(shift_rate: '1.5').rows.find { |candidate| candidate.employee == @worker }
    pay = EmployeePayWeek.new(employee: @worker, week_of: Date.new(2026, 10, 10))
    assert_equal pay.commission_cents, row.current_cents
    assert_equal 10_000, row.sales_cents
    assert_equal 150, row.plan_cents
    assert_equal 50, row.difference_cents
    assert_in_delta 3.0, row.hours, 0.001
  end

  test 'trainees get the training rate only in weeks over the hours threshold' do
    trainee = { trainees: [@worker.id.to_s], training_rate: '2' }
    over = model(**trainee, training_hours: '2').rows.first
    assert_equal 200, over.plan_cents
    assert_equal 1, over.training_weeks
    under = model(**trainee, training_hours: '5').rows.first
    assert_equal 100, under.plan_cents
    assert_equal 0, under.training_weeks
  end

  test 'rates are clamped and a period with no shifts has no rows' do
    assert_equal 10.0, IncentiveModel.plan_from(shift_rate: '50').shift_rate
    empty = IncentiveModel.new(plan: IncentiveModel.plan_from({}), period: 'custom', from: '2026-09-01', to: '2026-09-07',
      today: Date.new(2026, 10, 20))
    assert_empty empty.rows
    assert_nil empty.cost_per_hour_cents
  end
end
