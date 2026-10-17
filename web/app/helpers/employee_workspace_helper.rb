# frozen_string_literal: true

module EmployeeWorkspaceHelper
  def personal_reports_path(**options)
    @preview ? employee_preview_reports_path(**options) : employee_reports_path(**options)
  end

  def personal_time_off_path(**options)
    @preview ? employee_preview_time_off_path(**options) : employee_time_off_path(**options)
  end

  def personal_schedule_path(**options)
    @preview ? employee_preview_schedule_path(**options) : employee_schedule_path(**options)
  end

  def personal_time_clock_path
    @preview ? employee_preview_time_clock_path : time_clock_path
  end
end
