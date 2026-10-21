# frozen_string_literal: true

require 'csv'

module People
  # Admin/reviewer punch history. Reads Rupert clock shifts and imported Square
  # timecards side by side. Read-only: it never creates, edits or approves
  # payroll, and overlapping Square/Rupert punches are never added together.
  class PunchHistoryController < AuthenticatedController
    before_action -> { response.headers['Cache-Control'] = 'no-store' }
    before_action :authorize_history
    before_action :set_scope, only: %i[index]

    def index
      @view = %w[calendar list].include?(params[:view]) ? params[:view] : 'list'
      @history = PunchHistory.new(from: @from, to: @to, employee_id: params[:employee_id].presence,
        source: params[:source].presence, status: params[:status].presence,
        all_employees: @all_employees, worker_id: @worker_id)
      @summary = @history.summary
      @employees = @all_employees ? People::Employee.order(:last_name, :first_name) : People::Employee.where(id: @worker_id)
      if request.format.csv?
        return send_data @history.to_csv, filename: "punch-history-#{@from.iso8601}-to-#{@to.iso8601}.csv", type: 'text/csv'
      end

      @month = (@from.beginning_of_month..@from.end_of_month)
      @calendar_days = @history.calendar_days
      @rows = @history.rows
      @coverage = TimeSourceCoverage.for(Current.user)
    rescue Date::Error
      redirect_to people_punch_history_path, alert: 'Choose valid dates.'
    end

    private

    def authorize_history
      authorize(People::Timesheet, :index?)
    end

    def set_scope
      @all_employees = Current.user.can_review_timesheets? || (Current.user.can_manage_accounts? && Current.user.can?('timesheets.read'))
      @worker_id = @all_employees ? nil : TimeClockService.worker_for(Current.user, include_on_leave: true)&.id
      @from = parse_date(params[:from]) || Date.current.beginning_of_month
      @to = parse_date(params[:to]) || Date.current
      redirect_to people_punch_history_path, alert: 'Choose an end date on or after the start date.' if @to < @from
    rescue Date::Error
      redirect_to people_punch_history_path, alert: 'Choose valid dates.'
    end

    def parse_date(value)
      return nil if value.blank?

      Date.iso8601(value)
    end
  end
end
