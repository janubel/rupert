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

# Receipt status words and pills (My receipts). Returned receipts say so in plain words.
module EmployeeWorkspaceHelper
  def receipt_status_label(status)
    status.to_s == 'rejected' ? 'Returned for correction' : status.to_s.humanize
  end

  def receipt_status_pill_class(status)
    { 'draft' => 'pill-taupe', 'submitted' => 'pill-olive', 'approved' => 'pill-fern', 'rejected' => 'pill-clay' }.fetch(status.to_s, 'pill-taupe')
  end
end
