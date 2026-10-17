# frozen_string_literal: true

module Api
  module V1
    class EmployeeTimesheetsController < EmployeeBaseController
      def index
        render json: { data: worker.timesheets.order(period_start: :desc).limit(104).map { |sheet| summary(sheet) } }
      end

      def show
        render_sheet(find_sheet)
      end

      def create
        # Always force the authenticated worker, even for manager accounts.
        sheet = TimesheetWorkflow.new.create(params.require(:timesheet).permit(:period_start, :period_end, :notes).to_h.merge(employee_id: worker.id))
        render_sheet(sheet, status: :created)
      end

      def update
        sheet = find_sheet
        TimesheetWorkflow.new.change(sheet, :update, params.require(:timesheet).permit(:period_start, :period_end, :notes))
        render_sheet(sheet)
      end

      def destroy
        TimesheetWorkflow.new.change(find_sheet, :destroy)
        head :no_content
      end

      def transition
        event = params[:event].to_s
        return render(json: { error: 'unsupported_action' }, status: :unprocessable_entity) unless %w[submit reopen import_shifts].include?(event)
        sheet = find_sheet
        # The employee API never reviews or reopens approved records, regardless of browser role.
        return forbidden if event == 'reopen' && !sheet.rejected?
        TimesheetWorkflow.new.change(sheet, event)
        render_sheet(sheet)
      end

      def entry
        sheet = find_sheet
        action = { 'POST' => :add_entry, 'PATCH' => :update_entry, 'DELETE' => :remove_entry }.fetch(request.method)
        attrs = request.delete? ? {} : params.require(:timesheet_entry).permit(:worked_on, :hours, :work_type, :notes).to_h
        TimesheetWorkflow.new.change(sheet, action, attrs.merge(entry_id: params[:entry_id]))
        render_sheet(sheet)
      end

      private

      def find_sheet
        worker.timesheets.find(params[:id])
      end

      def summary(sheet)
        sheet.as_json(only: %i[id period_start period_end status notes submitted_at reviewed_at review_note demo]).merge(total_hours: sheet.total_hours.to_s('F'))
      end

      def render_sheet(sheet, status: :ok)
        render json: { data: summary(sheet).merge(entries: sheet.entries.ordered.as_json(only: %i[id worked_on hours work_type notes clock_shift_id]),
          history: sheet.events.order(:id).as_json(only: %i[action details created_at])) }, status: status
      end
    end
  end
end
