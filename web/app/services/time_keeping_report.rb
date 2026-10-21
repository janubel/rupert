# frozen_string_literal: true

require 'csv'

# Time keeping: planned schedules side by side with hours worked, for any date
# range. Read-only reporting; nothing here edits shifts, punches or payroll.
#
#   Scheduled — People::ScheduledShift (the plan, never proof of work)
#   Worked    — counted punches from PunchHistory: Rupert clock shifts and
#               imported Square timecards. Rupert wins where they overlap, so
#               the same shift is never counted twice.
#   C-Trax    — register shifts observed in C-Trax, shown in their own column
#               and never added to worked hours.
#
# A scheduled shift is placed on the day it starts; a punch on its clock-in day.
class TimeKeepingReport
  MAX_DAYS = 400
  # Worked hours this far from the plan are called out.
  VARIANCE_ALERT_HOURS = 0.5

  class Error < StandardError; end

  Day = Struct.new(:date, :employee_id, :employee_name, :shifts, :punches, keyword_init: true) do
    def scheduled_hours = shifts.sum(&:hours).round(2)
    def worked_hours = punches.select(&:counted).sum { |row| row.hours.to_f }.round(2)
    def ctrax_hours = punches.select { |row| row.source == 'ctrax' }.sum { |row| row.hours.to_f }.round(2)
    def variance = (worked_hours - scheduled_hours).round(2)
    def schedule_label = shifts.map(&:time_label).join(', ')
    def sources = punches.map(&:source).uniq.sort
    def open_punch? = punches.any? { |row| row.status == 'open' }
    def implausible? = punches.any?(&:implausible?)

    # One plain-language status per person-day, most important first.
    def status
      if open_punch? then implausible? ? 'Missed clock-out' : 'Still clocked in'
      elsif shifts.any? && punches.none?(&:counted)
        ctrax_hours.positive? ? 'Scheduled · C-Trax only' : 'No punches'
      elsif shifts.empty? && punches.any?(&:counted) then 'Unscheduled'
      elsif implausible? then 'Check clock-out'
      elsif variance.abs > VARIANCE_ALERT_HOURS then variance.positive? ? 'Over schedule' : 'Under schedule'
      elsif shifts.any? then 'On schedule'
      else 'C-Trax only'
      end
    end

    def attention? = !['On schedule', 'C-Trax only'].include?(status)
  end

  Staff = Struct.new(:employee_id, :employee_name, :scheduled_hours, :worked_hours, :ctrax_hours, :variance,
    :scheduled_days, :worked_days, :no_punch_days, :unscheduled_days, :attention_days, :shifts, keyword_init: true)

  attr_reader :from, :to, :employee_id

  # all_employees/worker_id mirror PunchHistory: reviewers see everyone, other
  # staff see only themselves.
  def initialize(from:, to:, employee_id: nil, all_employees: false, worker_id: nil)
    @from = from
    @to = to
    @all_employees = all_employees
    @worker_id = worker_id
    @employee_id = employee_id.presence&.to_i
    raise Error, 'The end date must be on or after the start date.' if to < from
    raise Error, "Choose a range of #{MAX_DAYS} days or fewer." if (to - from).to_i >= MAX_DAYS
  end

  def dates = (from..to).to_a

  def scheduled_shifts
    @scheduled_shifts ||= begin
      scope = People::ScheduledShift.includes(:employee)
        .where(starts_at: from.in_time_zone.beginning_of_day...(to + 1).in_time_zone.beginning_of_day)
      scope = scope.where(employee_id: visible_employee_ids) if visible_employee_ids
      scope.chronological.to_a
    end
  end

  def punches
    @punches ||= PunchHistory.new(from: from, to: to, employee_id: employee_id, all_employees: @all_employees, worker_id: @worker_id).rows
      .select(&:employee_id)
  end

  # Every person-day with a scheduled shift or a punch, oldest first.
  def days
    @days ||= begin
      keys = scheduled_shifts.map { |shift| [shift.starts_at.to_date, shift.employee_id] } +
             punches.map { |row| [row.started_at.to_date, row.employee_id] }
      shifts = scheduled_shifts.group_by { |shift| [shift.starts_at.to_date, shift.employee_id] }
      worked = punches.group_by { |row| [row.started_at.to_date, row.employee_id] }
      keys.uniq.map do |date, person|
        Day.new(date: date, employee_id: person, employee_name: names[person] || 'Staff member',
          shifts: shifts.fetch([date, person], []), punches: worked.fetch([date, person], []).sort_by(&:started_at))
      end.sort_by { |day| [day.date, day.employee_name.downcase] }
    end
  end

  def days_by_date = @days_by_date ||= days.group_by(&:date)

  def staff
    @staff ||= days.group_by(&:employee_id).map do |person, list|
      Staff.new(employee_id: person, employee_name: list.first.employee_name,
        scheduled_hours: list.sum(&:scheduled_hours).round(2), worked_hours: list.sum(&:worked_hours).round(2),
        ctrax_hours: list.sum(&:ctrax_hours).round(2), variance: list.sum(&:variance).round(2),
        scheduled_days: list.count { |day| day.shifts.any? }, worked_days: list.count { |day| day.worked_hours.positive? },
        no_punch_days: list.count { |day| day.status.start_with?('Scheduled ·') || day.status == 'No punches' },
        unscheduled_days: list.count { |day| day.status == 'Unscheduled' },
        attention_days: list.count(&:attention?), shifts: list.sum { |day| day.shifts.size })
    end.sort_by { |row| row.employee_name.downcase }
  end

  # People shown as roster rows: everyone with activity, plus active staff in
  # scope so an empty schedule is visible too.
  def roster_people
    @roster_people ||= begin
      scope = People::Employee.where(status: %w[active on_leave])
      scope = scope.where(id: visible_employee_ids) if visible_employee_ids
      people = scope.order(:last_name, :first_name).map { |person| [person.id, person.name] }
      extra = staff.reject { |row| people.any? { |id, _| id == row.employee_id } }.map { |row| [row.employee_id, row.employee_name] }
      people + extra
    end
  end

  def roster_cell(employee, date) = (@roster_index ||= days.index_by { |day| [day.employee_id, day.date] })[[employee, date]]

  def totals
    { scheduled: staff.sum(&:scheduled_hours).round(2), worked: staff.sum(&:worked_hours).round(2),
      ctrax: staff.sum(&:ctrax_hours).round(2), shifts: scheduled_shifts.size, people: staff.size,
      attention: days.count(&:attention?) }
  end

  DAILY_HEADERS = ['Date', 'Staff member', 'Scheduled', 'Scheduled hours', 'Worked hours', 'Variance', 'C-Trax observed hours',
                   'Punches', 'Sources', 'Status'].freeze
  STAFF_HEADERS = ['Staff member', 'Scheduled shifts', 'Scheduled hours', 'Worked hours', 'Variance', 'C-Trax observed hours',
                   'Days scheduled', 'Days worked', 'Scheduled without punches', 'Unscheduled days', 'Days needing attention'].freeze
  SHIFT_HEADERS = ['Staff member', 'Start', 'End', 'Hours', 'Role', 'Notes'].freeze

  def daily_matrix
    days.map do |day|
      [day.date.iso8601, day.employee_name, day.schedule_label.presence || 'Not scheduled', day.scheduled_hours, day.worked_hours,
       day.variance, day.ctrax_hours, day.punches.size, day.sources.map { |source| source_label(source) }.join(' + '), day.status]
    end
  end

  def staff_matrix
    staff.map do |row|
      [row.employee_name, row.shifts, row.scheduled_hours, row.worked_hours, row.variance, row.ctrax_hours,
       row.scheduled_days, row.worked_days, row.no_punch_days, row.unscheduled_days, row.attention_days]
    end
  end

  def shift_matrix
    scheduled_shifts.map do |shift|
      [shift.employee&.name, shift.starts_at.iso8601, shift.ends_at.iso8601, shift.hours.round(2), shift.role_label, shift.notes]
    end
  end

  # kind: daily (default), staff or shifts.
  def to_csv(kind = 'daily')
    headers, matrix = { 'staff' => [STAFF_HEADERS, staff_matrix], 'shifts' => [SHIFT_HEADERS, shift_matrix] }
      .fetch(kind.to_s, [DAILY_HEADERS, daily_matrix])
    CSV.generate do |csv|
      csv << ['Time keeping', "From #{from}", "To #{to}", 'Worked = counted Rupert clock and Square punches; C-Trax is observed only']
      csv << headers
      matrix.each { |row| csv << row.map { |cell| TimesheetCsv.cell(cell) } }
    end
  end

  def source_label(source) = { 'rupert' => 'Rupert clock', 'square' => 'Square', 'ctrax' => 'C-Trax' }.fetch(source.to_s, source.to_s)

  private

  def visible_employee_ids
    return @visible_employee_ids if defined?(@visible_employee_ids)

    @visible_employee_ids =
      if !@all_employees then [@worker_id].compact
      elsif employee_id then [employee_id]
      end
  end

  def names
    @names ||= People::Employee.where(id: (scheduled_shifts.map(&:employee_id) + punches.map(&:employee_id)).uniq)
      .to_h { |person| [person.id, person.name] }
  end
end
