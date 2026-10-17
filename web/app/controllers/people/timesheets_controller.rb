# frozen_string_literal: true

require 'csv'
module People
  class TimesheetsController < AuthenticatedController
    before_action :prevent_caching
    before_action :set_timesheet, except: %i[index new create bulk_approve]
    rescue_from TimesheetWorkflow::Error, ActiveRecord::RecordInvalid, AASM::InvalidTransition, with: :workflow_error

    def index
      authorize(People::Timesheet, :index?)
      @reviewer = Current.user.can_review_timesheets? || People::TimesheetPolicy.assigned_demos(Current.user).exists?
      @status = params[:status].presence || (@reviewer ? 'submitted' : 'all')
      @status = 'all' unless (People::Timesheet.aasm.states.map { |state| state.name.to_s } + ['all']).include?(@status)
      @period = params[:period].presence
      @query = params[:q].to_s.strip.first(80).presence
      visible = People::TimesheetPolicy.visible_to(Current.user)
      @has_demo_timesheets = visible.demo_records.exists?
      @awaiting = visible.awaiting_review.count
      scoped = visible
      if @period
        day = Date.iso8601(@period)
        @week_start = day.beginning_of_week
        scoped = scoped.where('period_start <= ? AND period_end >= ?', day.end_of_week, day.beginning_of_week)
      end
      scoped = scoped.joins(:employee).merge(search_employees(@query)) if @query
      @status_counts = scoped.group(:status).count
      scope = scoped.by_status(@status)
      if request.format.csv?
        return send_data TimesheetCsv.generate(scope), filename: 'timesheets.csv', type: 'text/csv'
      end
      @calendar_view = @reviewer && Current.user.can?('timesheets.read')
      if @calendar_view
        @week_start ||= Date.current.beginning_of_week
        @calendar = TimesheetCalendar.new(@week_start, user: Current.user)
      end
      @square_history = SquareTimecard.visible_to(Current.user)
      @ctrax_history = CtraxLaborShift.visible_to(Current.user)
      @pagy, @timesheets = pagy(scope.order(period_start: :desc, id: :desc).includes(:employee, :assigned_reviewer), items: 30)
      @summaries = TimesheetInsights.summaries(@timesheets.to_a)
      @missing = TimesheetInsights.missing_for_week(@week_start || Date.current) if @reviewer && Current.user.can?('timesheets.write') && !@query
      @view_hours = People::TimesheetEntry.where(timesheet_id: scope.reorder(nil).select(:id)).sum(:hours)
    rescue Date::Error
      redirect_to people_timesheets_path, alert: 'Choose a valid period date.'
    end

    # Approve several submitted sheets in one step. Each goes through the same
    # per-sheet policy and workflow checks as a single approval; failures are
    # reported by employee and never block the others.
    def bulk_approve
      authorize(People::Timesheet, :index?)
      ids = Array(params[:timesheet_ids]).map(&:to_i).first(100)
      raise TimesheetWorkflow::Error, 'Select at least one timesheet to approve.' if ids.empty?

      approved = 0
      failures = []
      People::TimesheetPolicy.visible_to(Current.user).where(id: ids).includes(:employee).each do |sheet|
        unless People::TimesheetPolicy.new(Current.user, sheet).approve? && sheet.submitted?
          failures << "#{sheet.employee&.name}: not available for your approval"
          next
        end
        workflow.change(sheet, :approve, review_note: params[:review_note])
        approved += 1
      rescue TimesheetWorkflow::Error, ActiveRecord::RecordInvalid, AASM::InvalidTransition => e
        failures << "#{sheet.employee&.name}: #{e.is_a?(ActiveRecord::RecordInvalid) ? e.record.errors.full_messages.to_sentence : e.message}"
      end
      flash[:notice] = "#{approved} timesheet#{approved == 1 ? '' : 's'} approved." if approved.positive?
      flash[:alert] = "Not approved — #{failures.to_sentence}" if failures.any?
      redirect_to people_timesheets_path(status: params[:return_status].presence, period: params[:return_period].presence, q: params[:return_q].presence)
    end

    def show
      authorize(@timesheet)
      @entry = People::TimesheetEntry.new(timesheet: @timesheet, worked_on: [Date.current, @timesheet.period_end].min)
      @summary = TimesheetInsights.summaries([@timesheet]).fetch(@timesheet.id)
      visible = People::TimesheetPolicy.visible_to(Current.user)
      mine = visible.where(employee_id: @timesheet.employee_id)
      @previous_sheet = mine.where('period_start < ?', @timesheet.period_start).order(period_start: :desc).first
      @next_sheet = mine.where('period_start > ?', @timesheet.period_start).order(:period_start).first
      @next_awaiting = visible.awaiting_review.where.not(id: @timesheet.id).order(:submitted_at, :id).first
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
        following = if params[:continue].present? && %i[approve reject].include?(event)
          People::TimesheetPolicy.visible_to(Current.user).awaiting_review.where.not(id: @timesheet.id).order(:submitted_at, :id).first
        end
        notice = "Timesheet #{event.to_s.tr('_', ' ')} completed."
        if following
          redirect_to people_timesheet_path(following), notice: "#{notice} Here is the next one awaiting review."
        else
          redirect_to people_timesheet_path(@timesheet), notice: notice
        end
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

    def search_employees(term)
      like = "%#{ActiveRecord::Base.sanitize_sql_like(term.downcase)}%"
      People::Employee.where("LOWER(employees.first_name || ' ' || employees.last_name) LIKE ?", like)
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
