# frozen_string_literal: true

module People
  # Managers plan shifts here; employees read their own in the personal workspace.
  class ScheduledShiftsController < AuthenticatedController
    before_action :set_shift, only: %i[edit update destroy]
    rescue_from Date::Error, with: :invalid_week

    def index
      authorize(:module, :hr_read?)
      day = params[:week].present? ? Date.iso8601(params[:week]) : Date.current
      raise Date::Error unless (1900..2100).cover?(day.year)

      @week = day.beginning_of_week
      @shifts = People::ScheduledShift.between(@week, @week + 6).chronological.includes(:employee)
      @by_employee = @shifts.group_by(&:employee).sort_by { |employee, _| [employee.last_name.to_s, employee.first_name.to_s] }
    end

    def new
      authorize(:module, :hr_write?)
      day = params[:date].present? ? Date.iso8601(params[:date]) : Date.current
      @shift = People::ScheduledShift.new(employee_id: params[:employee_id], starts_at: day.in_time_zone + 9.hours, ends_at: day.in_time_zone + 17.hours)
      load_employees
    end

    def create
      authorize(:module, :hr_write?)
      @shift = People::ScheduledShift.new(shift_params)
      if @shift.save
        ActivityLogger.log('scheduled_shift_created', subject: @shift, details: shift_details)
        redirect_to(people_scheduled_shifts_path(week: @shift.starts_at.to_date.iso8601), notice: 'Shift scheduled.')
      else
        load_employees
        render(:new, status: :unprocessable_entity)
      end
    end

    def edit
      authorize(:module, :hr_write?)
      load_employees
    end

    def update
      authorize(:module, :hr_write?)
      if @shift.update(shift_params)
        ActivityLogger.log('scheduled_shift_updated', subject: @shift, details: shift_details)
        redirect_to(people_scheduled_shifts_path(week: @shift.starts_at.to_date.iso8601), notice: 'Shift updated.')
      else
        load_employees
        render(:edit, status: :unprocessable_entity)
      end
    end

    def destroy
      authorize(:module, :hr_write?)
      @shift.destroy!
      ActivityLogger.log('scheduled_shift_deleted', subject: @shift, details: shift_details)
      redirect_to(people_scheduled_shifts_path(week: @shift.starts_at.to_date.iso8601), notice: 'Shift removed.')
    end

    private

    def set_shift
      @shift = People::ScheduledShift.find_by!(tenant_id: Current.tenant_id, id: params[:id])
    end

    def load_employees
      @employees = People::Employee.active.ordered
    end

    def shift_params
      params.require(:scheduled_shift).permit(:employee_id, :starts_at, :ends_at, :role_label, :notes)
    end

    def shift_details
      "#{@shift.employee&.full_name} · #{@shift.starts_at.strftime('%b %-d %-l:%M %p')} – #{@shift.ends_at.strftime('%-l:%M %p')}"
    end

    def invalid_week
      redirect_to(people_scheduled_shifts_path, alert: 'Choose a valid week.')
    end
  end
end
