# frozen_string_literal: true

require 'csv'

# Employee-scoped reads only. Clock hours and timesheet hours are kept separate
# so importing a shift never doubles either hours or the gross estimate.
class EmployeeWorkSummary
  attr_reader :employee, :from, :to, :entries, :shifts, :requests, :rates

  def initialize(employee:, from:, to:)
    raise ArgumentError, 'Choose a date range of up to one year.' unless from && to && to >= from && to <= from + 365
    raise ActiveRecord::RecordNotFound unless employee&.tenant_id == Current.tenant_id

    @employee, @from, @to = employee, from, to
    @entries = employee.timesheet_entries.where(worked_on: from..to).includes(:timesheet).order(:worked_on, :id).to_a
    @shifts = ClockShift.where(employee_id: employee.id, user_id: employee.user_id)
      .where('started_at < ? AND (ended_at IS NULL OR ended_at > ?)', (to + 1).in_time_zone, from.in_time_zone).order(:started_at).to_a
    @requests = employee.leave_requests.where('starts_on <= ? AND ends_on >= ?', to, from).order(:starts_on, :id).to_a
    @rates = employee.pay_rates.where('effective_on <= ?', to).order(effective_on: :desc, id: :desc).to_a
  end

  def self.preview
    EmployeePreview.new.summary
  end

  def hours
    entries.sum(&:hours)
  end

  def clock_hours(day = nil)
    start_at = (day || from).in_time_zone
    end_at = ((day || to) + 1).in_time_zone
    shifts.sum do |shift|
      start = [shift.started_at, start_at].max
      finish = [shift.ended_at || Time.current, end_at].min
      [finish - start, 0].max / 3600.0
    end
  end

  def rate_for(day)
    rates.find { |rate| rate.effective_on <= day && (rate.ended_on.nil? || rate.ended_on >= day) }
  end

  def estimated_cents(entry)
    rate = rate_for(entry.worked_on)
    return unless rate&.pay_type == 'hourly' && rate.hourly_rate_cents.positive?

    multiplier = entry.work_type == 'overtime' ? BigDecimal(People::PayrollCalculator::OVERTIME_MULTIPLIER.to_s) : 1
    (entry.hours * rate.hourly_rate_cents * multiplier).round.to_i
  end

  def gross_cents
    values = entries.map { |entry| estimated_cents(entry) }
    values.any?(&:nil?) || (entries.empty? && !(rate_for(to)&.pay_type == 'hourly' && rate_for(to).hourly_rate_cents.positive?)) ? nil : values.sum
  end

  def daily_hours(day)
    entries.select { |entry| entry.worked_on == day }.sum(&:hours)
  end

  def daily_requests(day)
    requests.select { |request| (request.starts_on..request.ends_on).cover?(day) && !request.cancelled? && !request.denied? }
  end

  def time_off_csv
    CSV.generate do |csv|
      csv << ['Type', 'First day', 'Last day', 'Hours requested', 'Status', 'Note']
      requests.each do |request|
        csv << [request.leave_type, request.starts_on, request.ends_on, request.hours&.to_s('F'), request.status, request.reason].map { |value| TimesheetCsv.cell(value) }
      end
    end
  end

  def csv
    CSV.generate do |csv|
      csv << ['Date', 'Timesheet status', 'Type', 'Hours', 'Estimated gross (USD)', 'Notes']
      entries.each do |entry|
        cents = estimated_cents(entry)
        csv << [entry.worked_on, entry.timesheet.status, entry.work_type, entry.hours.to_s('F'), cents && format('%.2f', cents / 100.0), entry.notes].map { |value| TimesheetCsv.cell(value) }
      end
    end
  end
end
