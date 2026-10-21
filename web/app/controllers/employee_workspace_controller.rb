# frozen_string_literal: true

# Personal workspace: every record starts from the signed-in worker link,
# never from an employee/user/tenant identifier supplied by the browser.
class EmployeeWorkspaceController < AuthenticatedController
  layout 'employee'
  before_action :private_response
  before_action :require_worker
  rescue_from Date::Error, ArgumentError, with: :invalid_range

  def reports
    load_report_data
    respond_to do |format|
      format.html
      format.csv do
        leave = params[:kind] == 'time_off'
        send_data(leave ? @summary.time_off_csv : @summary.csv, filename: "my-#{leave ? 'time-off' : 'hours'}-#{@from}-#{@to}.csv", type: 'text/csv')
      end
    end
  end

  def report_problem
    values = params.require(:work_report).permit(:kind, :details, :request_key)
    @work_report = @worker.work_reports.find_by(request_key: values[:request_key]) if values[:request_key].present?
    return redirect_to employee_reports_path(anchor: 'problems'), notice: 'Your report is already saved.' if @work_report

    @work_report = @worker.work_reports.new(values)
    @work_report.requester = Current.user
    if @work_report.save
      ActivityLogger.log('employee_work_report_created', subject: @work_report, details: 'Private staff problem report saved; awaiting review.')
      redirect_to employee_reports_path(anchor: 'problems'), notice: 'Your report was saved for administrator review.'
    else
      load_report_data
      render :reports, status: :unprocessable_entity
    end
  rescue ActiveRecord::RecordNotUnique
    redirect_to employee_reports_path(anchor: 'problems'), notice: 'Your report is already saved.'
  end

  def schedule
    load_schedule_week
    @shifts = @worker.scheduled_shifts.between(@week, @week + 6).chronological.to_a
    @requests = @worker.leave_requests.where(status: %w[requested approved]).where('starts_on <= ? AND ends_on >= ?', @week + 6, @week).to_a
  end

  def time_off
    @month = params[:month].present? ? Date.strptime("#{params[:month]}-01", '%Y-%m-%d') : Date.current.beginning_of_month
    raise ArgumentError, 'Choose a valid calendar month.' unless (1900..2100).cover?(@month.year) && (params[:month].blank? || params[:month] == @month.strftime('%Y-%m'))
    @summary = EmployeeWorkSummary.new(employee: @worker, from: @month, to: @month.end_of_month)
    @requests = @worker.leave_requests.order(starts_on: :desc).limit(100)
    @balances = @worker.leave_balances.for_year(@month.year).ordered
    @request ||= @worker.leave_requests.new(starts_on: Date.current, ends_on: Date.current)
  end

  def request_time_off
    @request = @worker.leave_requests.new(params.require(:leave_request).permit(:leave_type, :starts_on, :ends_on, :hours, :reason))
    @request.valid?
    @request.errors.add(:hours, 'must be entered for paid time off') if @request.leave_type != 'unpaid' && @request.hours.blank?
    @request.errors.add(:ends_on, 'must be in the same calendar year; submit a separate request for each year') if @request.starts_on && @request.ends_on && @request.starts_on.year != @request.ends_on.year
    if @request.errors.empty? && @request.save
      ActivityLogger.log('leave_requested', subject: @request, details: 'Staff self-service request; awaiting manager review.')
      redirect_to employee_time_off_path, notice: 'Time-off request sent for review.'
    else
      time_off
      render :time_off, status: :unprocessable_entity
    end
  end

  def cancel_time_off
    request = @worker.leave_requests.find(params[:id])
    if request.requested? && LeaveRequestWorkflow.change(request, :cancel, self_service: true)
      redirect_to employee_time_off_path, notice: 'Request cancelled.'
    else
      redirect_to employee_time_off_path, alert: 'Ask your manager to change time off that has already been reviewed.'
    end
  end

  private

  def load_schedule_week
    day = params[:week].present? ? Date.iso8601(params[:week]) : Date.current
    raise ArgumentError, 'Choose a valid week.' unless (1900..2100).cover?(day.year)

    @week = day.beginning_of_week
  end

  def load_report_data
    range = TimeRangePicker.resolve(params)
    @from = range.from || Date.current.beginning_of_week
    @to = range.to || Date.current.end_of_week
    @summary = EmployeeWorkSummary.new(employee: @worker, from: @from, to: @to)
    @payslips = @worker.payslips.joins(:pay_run).where(pay_runs: { tenant_id: Current.tenant_id, status: %w[finalized paid] })
      .where('pay_runs.period_start <= ? AND pay_runs.period_end >= ?', @to, @from).includes(:pay_run).order('pay_runs.period_end DESC')
    @work_reports = @worker.work_reports.includes(:reviewer).order(created_at: :desc).limit(50)
    @work_report ||= @worker.work_reports.new(request_key: SecureRandom.uuid, kind: 'time')
  end

  def private_response
    response.headers['Cache-Control'] = 'no-store'
  end

  def require_worker
    @worker = TimeClockService.worker_for(Current.user, include_on_leave: true)
    return if @worker

    redirect_to employee_app_path, alert: 'Ask an administrator to link your staff record before using your personal workspace.'
  end

  def invalid_range
    redirect_to employee_app_path, alert: 'Choose valid dates, with no more than one year in a report.'
  end
end
