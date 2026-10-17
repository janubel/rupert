# frozen_string_literal: true

# Read-only review aids for administrators: per-sheet hour breakdowns and
# plain-language flags. Nothing here approves, edits or pays anything.
class TimesheetInsights
  LONG_DAY_HOURS = 12
  WEEKLY_OVERTIME_HOURS = 40

  Summary = Struct.new(:regular, :overtime, :other, :total, :days_worked, :longest_day, :flags, keyword_init: true)

  # One grouped query for a page of sheets instead of one per row.
  def self.summaries(sheets)
    ids = sheets.map(&:id)
    rows = People::TimesheetEntry.where(timesheet_id: ids).group(:timesheet_id, :worked_on, :work_type).sum(:hours)
    by_sheet = rows.group_by { |(sheet_id, _day, _type), _hours| sheet_id }
    sheets.to_h { |sheet| [sheet.id, summarize(sheet, by_sheet.fetch(sheet.id, []))] }
  end

  def self.summarize(sheet, rows)
    totals = Hash.new(BigDecimal('0'))
    per_day = Hash.new(BigDecimal('0'))
    rows.each do |(_id, day, type), hours|
      totals[type] += hours
      per_day[day] += hours
    end
    total = totals.values.sum(BigDecimal('0'))
    summary = Summary.new(regular: totals['regular'], overtime: totals['overtime'],
      other: totals['pto'] + totals['holiday'], total: total, days_worked: per_day.size,
      longest_day: per_day.values.max || 0, flags: [])
    summary.flags = flags_for(sheet, summary)
    summary
  end

  def self.flags_for(sheet, summary)
    flags = []
    flags << 'No entries' if summary.total.zero?
    flags << 'Overtime recorded' if summary.overtime.positive?
    flags << "Over #{WEEKLY_OVERTIME_HOURS} hours without overtime" if summary.total - summary.other > WEEKLY_OVERTIME_HOURS && summary.overtime.zero? && (sheet.period_end - sheet.period_start) < 7
    flags << "Day over #{LONG_DAY_HOURS} hours" if summary.longest_day > LONG_DAY_HOURS
    flags << 'Employee inactive' if sheet.employee && !sheet.employee.active?
    flags
  end

  # Active employees with no timesheet overlapping the week containing +day+.
  def self.missing_for_week(day)
    from = day.beginning_of_week
    covered = People::Timesheet.where('period_start <= ? AND period_end >= ?', from + 6, from).select(:employee_id)
    People::Employee.active.where.not(id: covered).ordered
  end
end
