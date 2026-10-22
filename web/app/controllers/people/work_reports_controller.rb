# frozen_string_literal: true

module People
  class WorkReportsController < AuthenticatedController
    before_action :authorize_private_review
    before_action -> { response.headers['Cache-Control'] = 'no-store' }

    def index
      @status = EmployeeWorkReport::STATUSES.include?(params[:status]) ? params[:status] : 'all'
      scope = EmployeeWorkReport.includes(:employee, :reviewer).order(created_at: :desc)
      scope = scope.where(status: @status) unless @status == 'all'
      @pagy, @reports = pagy(:offset, scope, limit: 25)
    end

    def update
      report = EmployeeWorkReport.find(params[:id])
      values = params.require(:work_report).permit(:status, :response, :lock_version)
      unless values[:lock_version].to_s.match?(/\A\d+\z/) && values[:response].present?
        return redirect_to people_work_reports_path, alert: 'Enter a response and reload an outdated form.'
      end
      report.update!(values.merge(reviewer: Current.user, reviewed_at: Time.current))
      ActivityLogger.log('employee_work_report_reviewed', subject: report, details: "Status: #{report.status}; response available in the private staff workspace.")
      redirect_to people_work_reports_path, notice: 'Response saved for the staff member.'
    rescue ActiveRecord::StaleObjectError
      redirect_to people_work_reports_path, alert: 'Another administrator updated this report. Reload before responding.'
    rescue ActiveRecord::RecordInvalid => error
      redirect_to people_work_reports_path, alert: error.record.errors.full_messages.to_sentence
    end

    private

    def authorize_private_review
      raise Pundit::NotAuthorizedError unless Current.user.can_manage_accounts? && Current.user.can?('hr.read')
      raise Pundit::NotAuthorizedError if action_name == 'update' && !Current.user.can?('hr.write')
    end
  end
end
