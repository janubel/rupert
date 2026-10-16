# frozen_string_literal: true

# Synthetic records only: no employee association is queried or persisted.
# Readonly models also fail closed if a future caller accidentally tries saving.
class EmployeePreview
  attr_reader :employee, :sheets, :entries, :requests, :balances, :payslips, :work_reports, :shifts, :rate

  def initialize
    @start = Date.current.beginning_of_week
    @employee = example(People::Employee, first_name: 'Alex', last_name: 'Employee')
    @sheets = [sheet(@start, 'draft'), sheet(@start - 7, 'approved')]
    @entries = sheets.flat_map do |record|
      last_day = record.draft? ? [@start + 3, Date.current].min : record.period_start + 4
      (record.period_start..last_day).map do |day|
        example(People::TimesheetEntry, timesheet: record, worked_on: day, hours: 8, work_type: 'regular', notes: 'Example workday')
      end
    end
    @rate = example(People::PayRate, employee: employee, effective_on: @start - 365, pay_type: 'hourly', hourly_rate_cents: 2000, pay_frequency: 'weekly')
    @requests = [leave('vacation', @start + 10, 2, 16, 'requested', 'Example vacation request'), leave('personal', @start - 3, 1, 4, 'approved', 'Example appointment')]
    @balances = [example(People::LeaveBalance, employee: employee, year: Date.current.year, leave_type: 'vacation', accrued_hours: 80, used_hours: 16)]
    run = example(People::PayRun, name: 'Example pay period', period_start: @start - 7, period_end: @start - 1, paid_on: @start, status: 'paid')
    @payslips = [example(People::Payslip, employee: employee, pay_run: run, hours: 40, gross_cents: 80000, deductions_cents: 12000, net_cents: 68000)]
    @work_reports = [example(EmployeeWorkReport, employee: employee, kind: 'pay', status: 'resolved', details: 'Example: Please check the pay rate for last week.', response: 'Example response: Your rate was checked and the payslip is ready.', created_at: (@start - 2).in_time_zone + 10.hours, reviewed_at: (@start - 1).in_time_zone + 10.hours)]
    @shifts = entries.map do |entry|
      example(ClockShift, employee: employee, started_at: entry.worked_on.in_time_zone + 9.hours, ended_at: entry.worked_on.in_time_zone + 17.hours)
    end
  end

  def summary(from: @start, to: @start + 6)
    raise ArgumentError, 'Choose a date range of up to one year.' unless from && to && to >= from && to <= from + 365

    result = EmployeeWorkSummary.allocate
    { employee: employee, from: from, to: to, entries: entries.select { |entry| (from..to).cover?(entry.worked_on) }.sort_by(&:worked_on),
      rates: [rate], shifts: shifts.select { |shift| shift.started_at < (to + 1).in_time_zone && shift.ended_at > from.in_time_zone },
      requests: requests.select { |leave| leave.starts_on <= to && leave.ends_on >= from } }.each do |key, value|
      result.instance_variable_set("@#{key}", value)
    end
    result
  end

  private

  def example(model, attributes)
    record = model.new
    # Synthetic states are assigned without running workflow transitions.
    attributes.each { |key, value| key == :status ? record[key] = value : record.public_send("#{key}=", value) }
    record.readonly!
    record
  end

  def sheet(start, status)
    example(People::Timesheet, employee: employee, period_start: start, period_end: start + 6, status: status)
  end

  def leave(type, start, days, hours, status, reason)
    example(People::LeaveRequest, employee: employee, leave_type: type, starts_on: start, ends_on: start + days - 1, hours: hours, status: status, reason: reason)
  end
end
