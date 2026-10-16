# frozen_string_literal: true

require 'test_helper'

class EmployeeWorkSummaryTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
    @user = users(:regular_user)
    @worker = People::Employee.create!(first_name: 'Pay', last_name: 'Worker', user: @user)
    @from = Date.new(2026, 10, 5)
    @sheet = @worker.timesheets.create!(period_start: @from, period_end: @from + 6)
    @worker.pay_rates.create!(effective_on: @from, hourly_rate_cents: 2000)
    @worker.pay_rates.create!(effective_on: @from + 2, hourly_rate_cents: 2500)
    @worker.pay_rates.create!(effective_on: @from + 30, hourly_rate_cents: 9999)
    @sheet.entries.create!(worked_on: @from, hours: 8, work_type: 'regular')
    @sheet.entries.create!(worked_on: @from + 2, hours: 2, work_type: 'overtime')
  end
  teardown { Current.reset }

  def summary
    EmployeeWorkSummary.new(employee: @worker, from: @from, to: @from + 6)
  end

  test 'estimate uses effective dated rates marked overtime and never a future rate' do
    assert_equal 10, summary.hours
    assert_equal 23500, summary.gross_cents
    assert_equal 2000, summary.rate_for(@from).hourly_rate_cents
    assert_equal 2500, summary.rate_for(@from + 2).hourly_rate_cents
    assert_equal 2500, @worker.current_pay_rate.hourly_rate_cents
  end

  test 'missing and salary rates do not invent zero pay or a salary amount' do
    @worker.pay_rates.destroy_all
    assert_nil summary.gross_cents
    @worker.pay_rates.create!(effective_on: @from, pay_type: 'salary', annual_salary_cents: 5200000)
    assert_nil summary.gross_cents
  end

  test 'clock totals clip overnight shifts and do not double imported hours' do
    ClockShift.create!(user: @user, employee: @worker, employee_key: @worker.id.to_s, employee_name: @worker.name, employment_type: 'part_time', request_token: 'summary_clock_token_123', started_at: @from.in_time_zone - 1.hour, ended_at: @from.in_time_zone + 2.hours)
    assert_equal 2, summary.clock_hours
    assert_equal 2, summary.clock_hours(@from)
    assert_equal 10, summary.hours
    assert_equal 23500, summary.gross_cents
  end

  test 'record from a foreign workspace and excessive report windows are rejected' do
    other = Tenant.create!(name: 'Foreign pay', subdomain: 'foreign-pay-summary')
    worker = People::Employee.create!(tenant: other, first_name: 'Foreign', last_name: 'Employee')
    assert_raises(ActiveRecord::RecordNotFound) { EmployeeWorkSummary.new(employee: worker, from: @from, to: @from + 6) }
    assert_raises(ArgumentError) { EmployeeWorkSummary.new(employee: @worker, from: @from, to: @from + 366) }
  end
end
