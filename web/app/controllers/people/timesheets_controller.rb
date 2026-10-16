# frozen_string_literal: true

require 'csv'
module People
  class TimesheetsController < AuthenticatedController
    before_action :prevent_caching
    before_action :set_timesheet, except: %i[index new create]
    rescue_from TimesheetWorkflow::Error, ActiveRecord::RecordInvalid, AASM::InvalidTransition, with: :workflow_error

    def index
      authorize(People::Timesheet, :index?)
      @status = params[:status].presence || 'all'
      @period = params[:period].presence
      scope = People::TimesheetPolicy.visible_to(Current.user).by_status(@status)
      if @period
        day = Date.iso8601(@period)
        scope = scope.where('period_start <= ? AND period_end >= ?', day.end_of_week, day.beginning_of_week)
      end
      if request.format.csv?
        return send_data TimesheetCsv.generate(scope), filename: 'timesheets.csv', type: 'text/csv'
      end
      @awaiting = scope.awaiting_review.count
      @pagy, @timesheets = pagy(scope.order(period_start: :desc, id: :desc).includes(:employee), items: 30)
    rescue Date::Error
      redirect_to people_timesheets_path, alert: 'Choose a valid period date.'
    end

    def show
      authorize(@timesheet)
      @entry = @timesheet.entries.new(worked_on: [Date.current, @timesheet.period_end].min)
      respond_to do |format|
        format.html
        format.csv do
          send_data TimesheetCsv.generate(People::Timesheet.where(id: @timesheet.id)), filename: "timesheet-#{@timesheet.id}.csv", type: 'text/csv'
        end
      end
    end

    def new
      authorize(People::Timesheet, :create?)
      monday = Date.current.beginning_of_week
      @timesheet = People::Timesheet.new(period_start: monday, period_end: monday + 6)
      load_employees
    end

    def create
      @timesheet = workflow.create(timesheet_params)
      redirect_to people_timesheet_path(@timesheet), notice: 'Timesheet created — add hours or import your clock shifts.'
    rescue ActiveRecord::RecordInvalid => e
      @timesheet = e.record
      load_employees
      render :new, status: :unprocessable_entity
    end

    def edit
      authorize(@timesheet, :update?)
      raise TimesheetWorkflow::Error, 'Only draft timesheets can be edited.' unless @timesheet.draft?
      load_employees
    end

    def update
      workflow.change(@timesheet, :update, timesheet_params)
      redirect_to people_timesheet_path(@timesheet), notice: 'Timesheet updated.'
    rescue ActiveRecord::RecordInvalid
      load_employees
      render :edit, status: :unprocessable_entity
    end

    def destroy
      workflow.change(@timesheet, :destroy)
      redirect_to people_timesheets_path, notice: 'Draft deleted.'
    end

    %i[submit approve reject reopen import_shifts].each do |event|
      define_method(event) do
        workflow.change(@timesheet, event, review_note: params[:review_note])
        redirect_to people_timesheet_path(@timesheet), notice: "Timesheet #{event.to_s.tr('_', ' ')} completed."
      end
    end

    %i[add_entry update_entry remove_entry].each do |event|
      define_method(event) do
        attrs = event == :remove_entry ? {} : params.require(:timesheet_entry).permit(:worked_on, :hours, :work_type, :notes).to_h
        workflow.change(@timesheet, event, attrs.merge(entry_id: params[:entry_id]))
        redirect_to people_timesheet_path(@timesheet), notice: 'Timesheet entry saved.'
      end
    end

    private

    def prevent_caching
      response.headers['Cache-Control'] = 'no-store'
    end

    def workflow
      TimesheetWorkflow.new
    end

    def set_timesheet
      @timesheet = People::TimesheetPolicy.visible_to(Current.user).find(params[:id])
    end

    def load_employees
      @employees = Current.user.can?('timesheets.write') ? People::Employee.active.ordered : People::Employee.active.where(user_id: Current.user.id)
    end

    def timesheet_params
      params.require(:timesheet).permit(:employee_id, :period_start, :period_end, :notes)
    end

    def workflow_error(error)
      message = error.is_a?(ActiveRecord::RecordInvalid) ? error.record.errors.full_messages.to_sentence : error.message
      redirect_to(@timesheet&.persisted? ? people_timesheet_path(@timesheet) : people_timesheets_path, alert: message)
    end
  end
end
