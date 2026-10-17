# frozen_string_literal: true

require 'csv'
module People
  class TimesheetsController < AuthenticatedController
    before_action :prevent_caching
    before_action :set_timesheet, except: %i[index new create]
    rescue_from TimesheetWorkflow::Error, ActiveRecord::RecordInvalid, AASM::InvalidTransition, with: :workflow_error

    def index
      authorize(People::Timesheet, :index?)
      @reviewer = Current.user.can_review_timesheets? || People::TimesheetPolicy.assigned_demos(Current.user).exists?
      @status = params[:status].presence || (@reviewer ? 'submitted' : 'all')
      @status = 'all' unless (People::Timesheet.aasm.states.map { |state| state.name.to_s } + ['all']).include?(@status)
      @period = params[:period].presence
      @view = %w[calendar unified list].include?(params[:view]) ? params[:view] : 'unified'
      @all_employees_for_punches = Current.user.can_review_timesheets? || (Current.user.can_manage_accounts? && Current.user.can?('timesheets.read'))
      visible = People::TimesheetPolicy.visible_to(Current.user)
      @has_demo_timesheets = visible.demo_records.exists?
      @awaiting = visible.awaiting_review.count
      scope = visible.by_status(@status)
      if @period
        day = Date.iso8601(@period)
        scope = scope.where('period_start <= ? AND period_end >= ?', day.end_of_week, day.beginning_of_week)
      end
      if request.format.csv?
        return send_data TimesheetCsv.generate(scope), filename: 'timesheets.csv', type: 'text/csv'
      end
      @square_history = SquareTimecard.visible_to(Current.user)
      @ctrax_history = CtraxLaborShift.visible_to(Current.user)
      @pagy, @timesheets = pagy(scope.order(period_start: :desc, id: :desc).includes(:employee, :assigned_reviewer), items: 30)
      load_admin_overview(visible) if @reviewer
      # Calendar view: bucket timesheets (and punches) by every day they cover.
      if @view == 'calendar'
        @month = parse_month(params[:month]) || Date.current.beginning_of_month
        @month_days = @month.beginning_of_month..@month.end_of_month
        @calendar_start = @month.beginning_of_month.beginning_of_week(:monday)
        @calendar_days_range = (@calendar_start..(@calendar_start + 41.days))
        cal_scope = visible.by_status(@status).where('period_start <= ? AND period_end >= ?', @month.end_of_month, @month.beginning_of_month)
        punch_scope = if @all_employees_for_punches
          ClockShift.all
        else
          ClockShift.where(employee_id: TimeClockService.worker_for(Current.user, include_on_leave: true)&.id)
        end
        @calendar_days = @month_days.each_with_object({}) do |day, days|
          ts = cal_scope.select { |t| t.period_start <= day && t.period_end >= day }
          punches = punch_scope.select { |p| p.started_at.to_date == day }
          square = SquareTimecard.visible_to(Current.user).select { |c| c.started_at&.to_date == day }
          days[day.iso8601] = { timesheets: ts, punches: punches.size + square.size,
                                hours: (punches.sum { |p| ((p.ended_at || p.started_at) - p.started_at) / 3600.0 } + square.sum(&:hours).to_f).round(2) }
        end
        @prev_month = (@month - 1.month).beginning_of_month
        @next_month = (@month + 1.month).beginning_of_month
      end
      # Unified view: combine Rupert timesheets + Square timecards + C-Trax shifts
      # into one sortable list so every source is visible in a single place.
      if @view == 'unified'
        @unified = build_unified_records(visible)
        @page = [params[:page].to_i, 1].max
        @per_page = 40
        @pagy = Pagy.new(count: @unified.size, page: @page, items: @per_page)
        @unified_records = @unified.slice((@page - 1) * @per_page, @per_page) || []
      end
    rescue Date::Error
      redirect_to people_timesheets_path, alert: 'Choose a valid period date.'
    end

    def show
      authorize(@timesheet)
      @entry = People::TimesheetEntry.new(timesheet: @timesheet, worked_on: [Date.current, @timesheet.period_end].min)
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

    def build_unified_records(visible)
      records = []
      visible.includes(:employee, :assigned_reviewer).find_each do |ts|
        records << { source: 'Rupert', source_class: 'pill-olive', employee: ts.employee&.name || 'Unknown',
          date: ts.period_start, end_date: ts.period_end, hours: ts.total_hours.to_f, status: ts.status,
          detail: ts.demo? ? 'DEMO' : ts.period_label, path: people_timesheet_path(ts) }
      end
      SquareTimecard.visible_to(Current.user).includes(:employee).find_each do |card|
        records << { source: 'Square', source_class: 'pill-taupe', employee: card.employee&.name || 'Unmatched',
          date: card.started_at&.to_date, end_date: card.ended_at&.to_date, hours: card.hours.to_f, status: card.import_status,
          detail: "Timecard ##{card.external_id}", path: people_square_timesheet_path(card) }
      end
      CtraxLaborShift.visible_to(Current.user).includes(:employee).find_each do |shift|
        latest = helpers.ctrax_source_values(shift.latest_record) rescue {}
        hours = latest[:reported_hours] || latest[:elapsed_hours] || shift.reported_hours
        records << { source: 'C-Trax', source_class: 'pill-taupe', employee: shift.employee&.name || 'Unmatched',
          date: (shift.started_at || latest[:started_at])&.to_date, end_date: (shift.ended_at || latest[:ended_at])&.to_date,
          hours: hours&.to_f, status: shift.status, detail: "Shift ##{shift.external_id}", path: people_ctrax_timesheet_path(shift) }
      end
      records.sort_by { |r| r[:date] || Date.new(1970) }.reverse
    end

    # Navigation overview for reviewers: the next few weeks at a glance and
    # upcoming time off, so the timesheet page is a usable hub without
    # hunting through separate menus.
    def parse_month(value)
      return nil if value.blank?

      Date.iso8601(value.to_s + '-01').beginning_of_month
    rescue Date::Error
      nil
    end

    def load_admin_overview(visible)
      @upcoming_weeks = (0..3).map do |offset|
        monday = Date.current.beginning_of_week + offset.weeks
        week = visible.where('period_start <= ? AND period_end >= ?', monday + 6, monday)
        { monday: monday, label: offset.zero? ? 'This week' : monday.strftime('%b %-d'),
          total: week.count, submitted: week.by_status('submitted').count,
          approved: week.by_status('approved').count, draft: week.by_status('draft').count,
          rejected: week.by_status('rejected').count }
      end
      @upcoming_leave = People::LeaveRequest.where(status: %w[requested approved])
        .where('ends_on >= ?', Date.current).order(:starts_on).limit(8)
      @pending_leave_count = People::LeaveRequest.pending.count
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
