# frozen_string_literal: true

module People
  # Time keeping: schedules and hours worked for any date range, as a calendar,
  # a roster, a daily report and a staff summary, with CSV and PDF downloads.
  # Read-only. Reviewers see everyone; other staff see only themselves.
  class TimeKeepingController < AuthenticatedController
    VIEWS = %w[calendar roster daily staff].freeze

    before_action -> { response.headers['Cache-Control'] = 'no-store' }
    before_action -> { authorize(People::Timesheet, :index?) }

    def index
      @view = VIEWS.include?(params[:view]) ? params[:view] : 'calendar'
      @all_employees = Current.user.can_review_timesheets? || (Current.user.can_manage_accounts? && Current.user.can?('timesheets.read'))
      worker_id = @all_employees ? nil : TimeClockService.worker_for(Current.user, include_on_leave: true)&.id
      range = TimeRangePicker.resolve(params)
      @from = range.from || Date.current.beginning_of_month
      @to = range.to || Date.current.end_of_month
      @report = TimeKeepingReport.new(from: @from, to: @to, employee_id: (params[:employee_id] if @all_employees),
        all_employees: @all_employees, worker_id: worker_id)
      @employees = @all_employees ? People::Employee.order(:last_name, :first_name) : People::Employee.where(id: worker_id)

      respond_to do |format|
        format.html
        format.csv do
          kind = %w[daily staff shifts].include?(params[:kind]) ? params[:kind] : 'daily'
          log_export("Time keeping #{kind} CSV", "#{@from} to #{@to}")
          send_data(@report.to_csv(kind), filename: "time-keeping-#{kind}-#{@from}-to-#{@to}.csv", type: 'text/csv')
        end
        format.pdf do
          log_export('Time keeping PDF', "#{@from} to #{@to}")
          send_data(TimeKeepingPdf.new(@report).render, filename: "time-keeping-#{@from}-to-#{@to}.pdf",
            type: 'application/pdf', disposition: 'attachment')
        end
      end
    rescue TimeKeepingReport::Error, Date::Error => e
      redirect_to(people_time_keeping_path, alert: e.is_a?(Date::Error) ? 'Choose valid dates.' : e.message)
    end
  end
end
