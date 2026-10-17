# frozen_string_literal: true

module People
  # Team schedule: a grid of employees x days showing hours worked, pulled from
  # Rupert clock punches, Square timecards and C-Trax shifts. Read-only reporting.
  class TeamScheduleController < AuthenticatedController
    before_action -> { authorize(People::Timesheet, :index?) }
    before_action -> { response.headers['Cache-Control'] = 'no-store' }

    def index
      @week = parse_week(params[:week]) || Date.current.beginning_of_week
      @week_days = (@week..@week + 6).to_a
      @employees = People::Employee.where(status: 'active').order(:last_name, :first_name)
      @hours = build_hours(@employees, @week_days)
      @prev_week = @week - 7
      @next_week = @week + 7
    end

    private

    def parse_week(value)
      return nil if value.blank?

      Date.iso8601(value).beginning_of_week
    rescue Date::Error
      nil
    end

    def build_hours(employees, days)
      # { employee_id => { date_iso => hours } }
      result = employees.to_h { |e| [e.id, {}] }
      days.each { |d| result.each_value { |h| h[d.iso8601] = 0.0 } }

      # Rupert clock shifts
      ClockShift.where(started_at: days.first.beginning_of_day..days.last.end_of_day).each do |s|
        next unless s.employee_id && result.key?(s.employee_id)
        date = s.started_at.to_date.iso8601
        next unless result[s.employee_id].key?(date)
        hours = ((s.ended_at || s.started_at) - s.started_at) / 3600.0
        result[s.employee_id][date] += hours
      end

      # Square timecards
      SquareTimecard.where(started_at: days.first.beginning_of_day..days.last.end_of_day).each do |c|
        next unless c.employee_id && result.key?(c.employee_id)
        date = c.started_at.to_date.iso8601
        next unless result[c.employee_id].key?(date)
        result[c.employee_id][date] += c.hours.to_f
      end

      # C-Trax shifts
      CtraxLaborShift.where(started_at: days.first.beginning_of_day..days.last.end_of_day).each do |sh|
        next unless sh.employee_id && result.key?(sh.employee_id)
        date = sh.started_at.to_date.iso8601
        next unless result[sh.employee_id].key?(date)
        latest = helpers.ctrax_source_values(sh.latest_record) rescue {}
        hours = (latest[:reported_hours] || latest[:elapsed_hours] || sh.reported_hours || sh.elapsed_hours).to_f
        result[sh.employee_id][date] += hours
      end

      result
    end
  end
end
