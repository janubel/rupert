# frozen_string_literal: true

require 'csv'

module People
  class SquareTimesheetsController < AuthenticatedController
    before_action -> { response.headers['Cache-Control'] = 'no-store' }

    def index
      authorize(People::Timesheet, :index?)
      scope = SquareTimecard.visible_to(Current.user)
      scope = scope.where(employee_id: params[:employee_id]) if params[:employee_id].present? && Current.user.can_manage_accounts?
      scope = scope.where(import_status: params[:status]) if SquareTimecard::STATUSES.include?(params[:status])
      scope = scope.where('started_at >= ?', Date.iso8601(params[:from]).in_time_zone) if params[:from].present?
      scope = scope.where('started_at < ?', (Date.iso8601(params[:to]) + 1).in_time_zone) if params[:to].present?
      @count = scope.count
      @seconds = scope.counted.sum(:payable_seconds)
      @held = scope.where(imported_at: nil).count
      if request.format.csv?
        data = CSV.generate do |csv|
          csv << ['Employee', 'Square timecard ID', 'Clock-in', 'Clock-out', 'Timezone', 'Paid seconds', 'Hours', 'Import status', 'Counted in history']
          scope.includes(:employee).find_each do |card|
            csv << [card.employee&.name, card.external_id, card.started_at&.iso8601, card.ended_at&.iso8601, card.timezone, card.payable_seconds, card.hours.round(2).to_s('F'), card.import_status, card.imported_at.present?].map { |value| TimesheetCsv.cell(value) }
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
    end
  end
end
