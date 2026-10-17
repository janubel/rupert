# frozen_string_literal: true

require 'csv'

module People
  class CtraxTimesheetsController < AuthenticatedController
    before_action -> { response.headers['Cache-Control'] = 'no-store' }

    def index
      authorize(People::Timesheet, :index?)
      scope = CtraxLaborShift.visible_to(Current.user)
      @all_employees = Current.user.can_review_timesheets? || (Current.user.can_manage_accounts? && Current.user.can?('timesheets.read'))
      @employees = People::Employee.where(id: scope.select(:employee_id)).order(:last_name, :first_name) if @all_employees
      if @all_employees && params[:employee_id].present?
        scope = params[:employee_id] == 'unmatched' ? scope.where(employee_id: nil) : scope.where(employee_id: params[:employee_id])
      end
      scope = scope.where(status: params[:status]) if CtraxLaborShift::STATUSES.include?(params[:status])
      scope = scope.where('started_at >= ?', Date.iso8601(params[:from]).in_time_zone) if params[:from].present?
      scope = scope.where('started_at < ?', (Date.iso8601(params[:to]) + 1).in_time_zone) if params[:to].present?
      if request.format.csv?
        data = CSV.generate do |csv|
          csv << ['Employee', 'C-Trax shift ID', 'Store ID', 'Latest clock-in', 'Latest clock-out', 'Latest source-reported hours', 'Latest elapsed hours', 'Latest in progress', 'Latest source verified', 'Status', 'Review issue', 'Original clock-in', 'Original clock-out', 'Original source-reported hours', 'Original elapsed hours']
          scope.includes(:employee).find_each do |shift|
            latest = helpers.ctrax_source_values(shift.latest_record)
            csv << [shift.employee&.name, shift.external_id, shift.store_id, latest[:started_at]&.iso8601, latest[:ended_at]&.iso8601,
              latest[:reported_hours]&.to_s('F'), latest[:elapsed_hours]&.to_s('F'), latest[:in_progress], latest[:verified], shift.status, shift.issue,
              shift.started_at&.iso8601, shift.ended_at&.iso8601, shift.reported_hours&.to_s('F'), shift.elapsed_hours&.to_s('F')].map { |value| TimesheetCsv.cell(value) }
          end
        end
        return send_data data, filename: 'ctrax-shift-history.csv', type: 'text/csv'
      end
      @count = scope.count
      @open = scope.select(:id, :latest_payload).find_each.count { |shift| shift.latest_record['is_in_progress'] == true }
      @held = scope.where.not(status: 'imported').count
      @pagy, @shifts = pagy(scope.order(started_at: :desc, id: :desc).includes(:employee), items: 30)
    rescue Date::Error
      redirect_to people_ctrax_timesheets_path, alert: 'Choose valid dates.'
    end

    def show
      @shift = CtraxLaborShift.visible_to(Current.user).includes(:employee).find(params[:id])
      if request.format.csv?
        data = CSV.generate do |csv|
          csv << ['C-Trax shift ID', 'Observation', 'Observed at', 'Status', 'Issue', 'Clock-in', 'Clock-out', 'Source-reported hours', 'Elapsed hours', 'In progress', 'Source verified']
          @shift.observations.order(:sequence).each do |observation|
            values = helpers.ctrax_source_values(observation.record_data)
            csv << [@shift.external_id, observation.sequence, observation.observed_at.iso8601, observation.status, observation.issue,
              values[:started_at]&.iso8601, values[:ended_at]&.iso8601, values[:reported_hours]&.to_s('F'), values[:elapsed_hours]&.to_s('F'), values[:in_progress], values[:verified]].map { |value| TimesheetCsv.cell(value) }
          end
        end
        return send_data data, filename: 'ctrax-shift-observations.csv', type: 'text/csv'
      end
      @latest = helpers.ctrax_source_values(@shift.latest_record)
      @observation_count = @shift.observations.count
      @observations = @shift.observations.order(sequence: :desc).limit(50)
    end
  end
end
