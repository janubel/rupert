# frozen_string_literal: true

require 'csv'

module People
  class SquareTimesheetsController < AuthenticatedController
    before_action -> { response.headers['Cache-Control'] = 'no-store' }

    def index
      authorize(People::Timesheet, :index?)
      scope = SquareTimecard.visible_to(Current.user)
      @all_employees = Current.user.can_review_timesheets? || (Current.user.can_manage_accounts? && Current.user.can?('timesheets.read'))
      @employees = People::Employee.where(id: scope.select(:employee_id)).order(:last_name, :first_name) if @all_employees
      if @all_employees && params[:employee_id].present?
        scope = params[:employee_id] == 'unmatched' ? scope.where(employee_id: nil) : scope.where(employee_id: params[:employee_id])
      end
      scope = scope.where(import_status: params[:status]) if SquareTimecard::STATUSES.include?(params[:status])
      range = TimeRangePicker.resolve(params)
      @from = range.from
      @to = range.to
      return redirect_to(people_square_timesheets_path, alert: 'Choose an end date on or after the start date.') if @from && @to && @to < @from

      scope = scope.where('started_at >= ?', @from.in_time_zone) if @from
      scope = scope.where('started_at < ?', (@to + 1).in_time_zone) if @to
      @count = scope.count
      @seconds = scope.counted.sum(:payable_seconds)
      @held = scope.where(imported_at: nil).count
      if request.format.csv?
        data = CSV.generate do |csv|
          csv << ['Staff member', 'Square timecard ID', 'Original clock-in', 'Original clock-out', 'Original timezone', 'Original paid seconds', 'Original counted hours', 'Import status', 'Counted in history', 'Latest clock-in', 'Latest clock-out', 'Latest timezone', 'Latest source status', 'Latest break punches']
          scope.includes(:employee).find_each do |card|
            latest = helpers.square_latest_values(card)
            pauses = latest[:breaks].map { |pause| pause.merge(started_at: pause[:started_at]&.iso8601, ended_at: pause[:ended_at]&.iso8601) }
            csv << [card.employee&.name, card.external_id, card.started_at&.iso8601, card.ended_at&.iso8601, card.timezone, card.payable_seconds, card.hours.round(2).to_s('F'), card.import_status, card.imported_at.present?,
              latest[:started_at]&.iso8601, latest[:ended_at]&.iso8601, latest[:timezone], latest[:status], JSON.generate(pauses)].map { |value| TimesheetCsv.cell(value) }
          end
        end
        return send_data data, filename: 'square-timecard-history.csv', type: 'text/csv'
      end
      @pagy, @cards = pagy(scope.order(started_at: :desc, id: :desc).includes(:employee), items: 30)
    rescue Date::Error
      redirect_to people_square_timesheets_path, alert: 'Choose valid dates.'
    end

    def show
      @card = SquareTimecard.visible_to(Current.user).includes(:employee, :days).find(params[:id])
      @latest = helpers.square_latest_values(@card)
      if request.format.csv?
        data = CSV.generate do |csv|
          csv << ['Staff member', 'Square timecard ID', 'Record type', 'Clock-in', 'Clock-out', 'Timezone', 'Break name', 'Paid break', 'Original counted hours', 'Import status']
          csv << [@card.employee&.name, @card.external_id, 'Latest source punches', @latest[:started_at]&.iso8601,
            @latest[:ended_at]&.iso8601, @latest[:timezone], nil, nil, nil, @card.import_status].map { |value| TimesheetCsv.cell(value) }
          @latest[:breaks].each do |pause|
            csv << [@card.employee&.name, @card.external_id, 'Latest break punches', pause[:started_at]&.iso8601,
              pause[:ended_at]&.iso8601, @latest[:timezone], pause[:name], pause[:is_paid], nil, @card.import_status].map { |value| TimesheetCsv.cell(value) }
          end
          csv << [@card.employee&.name, @card.external_id, 'Original counted history', @card.started_at&.iso8601,
            @card.ended_at&.iso8601, @card.timezone, nil, nil, @card.imported_at ? @card.hours.to_s('F') : nil, @card.import_status].map { |value| TimesheetCsv.cell(value) }
        end
        send_data data, filename: 'square-timecard-punches.csv', type: 'text/csv'
      end
    end
  end
end
