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
      @view = %w[calendar unified list].include?(params[:view]) ? params[:view] : 'list'
      @all_employees_for_punches = Current.user.can_review_timesheets? || (Current.user.can_manage_accounts? && Current.user.can?('timesheets.read'))
      visible = People::TimesheetPolicy.visible_to(Current.user)
      @has_demo_timesheets = visible.demo_records.exists?
      @awaiting = visible.awaiting_review.count
      scoped = visible
      # Date range: dropdown preset or any Start/End date. An older week link
      # (?period=) still works and becomes that week's range.
      range = TimeRangePicker.resolve(params)
      @from, @to = range.from, range.to
      if @from.nil? && @to.nil? && @period
        @week_start = week_start_for(Date.iso8601(@period))
        @from, @to = @week_start, @week_start + 6
      end
      @from, @to = @to, @from if @from && @to && @to < @from
      scoped = scoped.where('period_end >= ?', @from) if @from
      scoped = scoped.where('period_start <= ?', @to) if @to
      @week_start ||= week_start_for(@from) if @from
      scoped = scoped.joins(:employee).merge(search_employees(@query)) if @query
      @status_counts = scoped.group(:status).count
      scope = scoped.by_status(@status)
      if request.format.csv?
        return send_data TimesheetCsv.generate(scope), filename: 'timesheets.csv', type: 'text/csv'
      end
      @coverage = TimeSourceCoverage.for(Current.user)
      @pagy, @timesheets = pagy(:offset, scope.order(period_start: :desc, id: :desc).includes(:employee, :assigned_reviewer), limit: 30)
      @summaries = TimesheetInsights.summaries(@timesheets.to_a)
      # The week schedule leads the page for anyone who can review time, with an employee key to switch people on and off.
      @calendar_view = @reviewer && Current.user.can?('timesheets.read')
      if @calendar_view
        @week_start ||= week_start_for(Date.current)
        @calendar = TimesheetCalendar.new(@week_start, user: Current.user)
      end
      @missing = TimesheetInsights.missing_for_week(@week_start || Date.current) if @reviewer && Current.user.can?('timesheets.write') && !@query
      @view_hours = People::TimesheetEntry.where(timesheet_id: scope.reorder(nil).select(:id)).sum(:hours)
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
        @pagy, @unified_records = pagy(:offset, @unified, page: @page, limit: @per_page)
      end
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
      redirect_to people_timesheets_path(status: params[:return_status].presence, period: params[:return_period].presence,
        from: params[:return_from].presence, to: params[:return_to].presence, q: params[:return_q].presence, view: 'list')
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
        following = if params[:continue].present? && event == :approve
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

    # Pay weeks may run Thursday through Wednesday. `wk=thu` snaps to Thursday,
    # `wk=custom` starts the seven days exactly on the chosen date, anything else is Monday-Sunday.
    def week_start_for(day)
      case params[:wk]
      when 'thu' then day.beginning_of_week(:thursday)
      when 'custom' then day
      else day.beginning_of_week
      end
    end
    helper_method :week_start_for

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
        counts = visible.where('period_start <= ? AND period_end >= ?', monday + 6, monday).group(:status).count
        { monday: monday, label: offset.zero? ? 'This week' : monday.strftime('%b %-d'),
          total: counts.values.sum, submitted: counts.fetch('submitted', 0),
          approved: counts.fetch('approved', 0), draft: counts.fetch('draft', 0),
          rejected: counts.fetch('rejected', 0) }
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
