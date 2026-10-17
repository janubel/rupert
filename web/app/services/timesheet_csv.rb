# frozen_string_literal: true

require 'csv'

class TimesheetCsv
  def self.generate(scope)
    CSV.generate do |out|
      out << %w[Employee Period_start Period_end Status Date Type Hours Notes Record_kind]
      scope.includes(:employee, :entries).find_each do |sheet|
        sheet.entries.sort_by { |entry| [entry.worked_on, entry.id] }.each do |entry|
          out << [sheet.employee.name, sheet.period_start, sheet.period_end, sheet.status,
            entry.worked_on, entry.work_type, entry.hours.to_s('F'), entry.notes,
            sheet.demo? ? 'DEMO: fictional hours; excluded from payroll' : 'Standard timesheet'].map { |value| cell(value) }
        end
      end
    end
  end

  def self.cell(value)
    text = value.to_s
    text.match?(/\A[=+\-@\t\r\n]/) ? "'#{text}" : text
  end
end
