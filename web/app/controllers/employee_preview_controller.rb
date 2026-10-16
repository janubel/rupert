# frozen_string_literal: true

# This controller has GET routes only and never loads real employee records.
class EmployeePreviewController < AuthenticatedController
  layout 'employee'
  before_action :prepare_preview
  rescue_from Date::Error, ArgumentError, with: :invalid_range

  def timesheets
    @sheets = @examples.sheets
  end

  def timesheet
    index = { 'current' => 0, 'previous' => 1 }[params[:id]]
    raise ActiveRecord::RecordNotFound if index.nil?

    @sheet = @examples.sheets.fetch(index)
    @summary = @examples.summary(from: @sheet.period_start, to: @sheet.period_end)
  end

  def pay
    @summary = @examples.summary
    @payslips = @examples.payslips
  end

  def time_clock
    @shifts = @examples.shifts.sort_by(&:started_at).reverse
  end

  def reports
    @from = params[:from].present? ? Date.iso8601(params[:from]) : Date.current.beginning_of_week - 7
    @to = params[:to].present? ? Date.iso8601(params[:to]) : Date.current.end_of_week
    @summary = @examples.summary(from: @from, to: @to)
    @payslips = @examples.payslips.select { |slip| slip.pay_run.period_start <= @to && slip.pay_run.period_end >= @from }
    @work_reports = @examples.work_reports
    @work_report = EmployeeWorkReport.new(kind: 'time').tap(&:readonly!)
    respond_to do |format|
      format.html { render 'employee_workspace/reports' }
      format.csv do
        leave = params[:kind] == 'time_off'
        send_data(leave ? @summary.time_off_csv : @summary.csv, filename: "example-#{leave ? 'time-off' : 'hours'}-#{@from}-#{@to}.csv", type: 'text/csv')
      end
    end
  end

  def time_off
    @month = params[:month].present? ? Date.strptime("#{params[:month]}-01", '%Y-%m-%d') : Date.current.beginning_of_month
    raise ArgumentError unless (1900..2100).cover?(@month.year) && (params[:month].blank? || params[:month] == @month.strftime('%Y-%m'))

    @summary = @examples.summary(from: @month, to: @month.end_of_month)
    @requests = @examples.requests
    @balances = @examples.balances.select { |balance| balance.year == @month.year }
    @request = People::LeaveRequest.new(starts_on: Date.current, ends_on: Date.current).tap(&:readonly!)
    render 'employee_workspace/time_off'
  end

  private

  def prepare_preview
    response.headers['Cache-Control'] = 'no-store'
    return head :forbidden unless Current.user.can_manage_accounts?

    @preview = true
    @examples = EmployeePreview.new
    @worker = @examples.employee
  end

  def invalid_range
    redirect_to employee_app_path(preview: 1), alert: 'Choose valid dates, with no more than one year in a report.'
  end
end
