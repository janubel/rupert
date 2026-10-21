# frozen_string_literal: true

# One consistent header across every time page (timesheets, punch report,
# Square and C-Trax history, team schedule, payroll) so an administrator can
# move between review, reporting and source history without hunting.
module TimeWorkspaceHelper
  def time_workspace_links
    user = Current.user
    return [] unless user&.active?

    reviewer = user.can_review_timesheets? || (user.can_manage_accounts? && user.can?('timesheets.read'))
    links = []
    links << ['Timesheets', people_timesheets_path, controller_path == 'people/timesheets']
    if user.can?('timesheets.read')
      links << ['Punch report', people_punch_history_path, controller_path == 'people/punch_history']
      links << ['Square history', people_square_timesheets_path, controller_path == 'people/square_timesheets']
      links << ['C-Trax history', people_ctrax_timesheets_path, controller_path == 'people/ctrax_timesheets']
    end
    links << ['Team schedule', people_team_schedule_path, controller_path == 'people/team_schedule'] if reviewer
    links << ['Payroll', people_pay_runs_path, controller_path == 'people/pay_runs'] if user.can?('payroll.read')
    links << ['Staff', people_employees_path, controller_path == 'people/employees'] if user.can?('hr.read')
    links
  end

  # Named reporting windows for the punch report. Pay weeks run Thursday–Wednesday.
  def time_report_presets(today = Date.current)
    pay_week = today.beginning_of_week(:thursday)
    [
      ['This pay week', pay_week, pay_week + 6],
      ['Last pay week', pay_week - 7, pay_week - 1],
      ['This month', today.beginning_of_month, today.end_of_month],
      ['Last month', (today - 1.month).beginning_of_month, (today - 1.month).end_of_month],
      ['Year to date', today.beginning_of_year, today],
      ['All history', Date.new(2000, 1, 1), today]
    ]
  end

  def time_source_label(source)
    { 'rupert' => 'Rupert clock', 'square' => 'Square', 'ctrax' => 'C-Trax' }.fetch(source.to_s, source.to_s.humanize)
  end

  def time_source_pill(source)
    { 'rupert' => 'pill-olive', 'square' => 'pill-taupe', 'ctrax' => 'pill-clay' }.fetch(source.to_s, 'pill-taupe')
  end

  def time_status_pill(status)
    case status.to_s
    when 'open', 'conflict', 'invalid', 'missing', 'deleted' then 'pill-rose'
    when 'imported', 'closed' then 'pill-fern'
    else 'pill-olive'
    end
  end
end
