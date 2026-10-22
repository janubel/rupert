# frozen_string_literal: true

require 'csv'

module Projects
  class ProjectsController < AuthenticatedController
    before_action :set_project, only: %i[show edit update destroy transition save_template]

    STATUS_FILTERS = %w[planned active on_hold completed archived].freeze
    EVENT_PAST = { 'start' => 'started', 'hold' => 'put on hold', 'complete' => 'completed', 'archive' => 'archived', 'reopen' => 'reopened' }.freeze

    def index
      authorize(:module, :projects_read?)
      @status = params[:status].presence_in(STATUS_FILTERS)
      scope = Projects::Project.all
      scope = @status ? scope.where(status: @status) : scope.where.not(status: 'archived')
      scope = scope.search(params[:q]) if params[:q].present?
      scope = case params[:sort]
              when 'name' then scope.order(Arel.sql('LOWER(projects.name)'))
              when 'due' then scope.order(Arel.sql('CASE WHEN projects.due_on IS NULL THEN 1 ELSE 0 END'), :due_on)
              else scope.order(updated_at: :desc)
              end
      @pagy, @projects = pagy(:offset, scope, limit: 18)
      @status_counts = Projects::Project.group(:status).count
      @overdue_tasks = Projects::Task.overdue.count
      @due_this_week = Projects::Task.due_within(7).count
      @open_tasks = Projects::Task.open.count + Projects::Task.where(status: 'blocked').count
      preload_task_counts(@projects)
    end

    def show
      authorize(@project)
      @view = params[:view] == 'timeline' ? 'timeline' : 'board'
      @board_total = @project.tasks.count
      tasks = @project.tasks.by_board_order.includes(:checklist_items).limit(TasksController::BOARD_LIMIT).to_a
      @columns = Projects::Task::BOARD_STATUSES.index_with { |s| tasks.select { |t| t.status == s } }
      ids = [*tasks.filter_map(&:assignee_id), @project.owner_id, *@project.project_members.pluck(:user_id)].compact.map(&:to_s).uniq
      @assignees = User.where(tenant_id: Current.tenant_id, id: ids).to_h { |u| [u.id.to_s, u.display_name] }
      @goal = @project.goal
      @timeline = build_timeline(tasks) if @view == 'timeline'
    end

    def export
      authorize(:module, :projects_read?)
      projects = Projects::Project.where.not(status: 'archived').order(:name).to_a
      preload_task_counts(projects)
      people = User.where(tenant_id: Current.tenant_id, id: projects.filter_map(&:owner_id)).to_h { |u| [u.id.to_s, u.display_name] }
      csv = CSV.generate do |out|
        out << ['Name', 'Status', 'Owner', 'Start', 'Due', 'Goal', 'Tasks', 'Done', 'Overdue', 'Blocked', 'Progress %', 'Health']
        projects.each do |project|
          out << [project.name, project.status, people[project.owner_id.to_s], project.start_on, project.due_on, project.goal&.name,
                  project.task_total, project.task_counts['done'], project.overdue_count, project.task_counts['blocked'],
                  project.progress_pct, project.health].map { |cell| csv_safe(cell) }
        end
      end
      log_export('Projects CSV', "#{projects.size} rows")
      send_data(csv, filename: "projects-#{Date.current.iso8601}.csv", type: 'text/csv; charset=utf-8')
    end

    def new
      authorize(:module, :projects_write?)
      @project = Projects::Project.new(start_on: Date.current)
      @templates = Projects::ProjectTemplate.alphabetical
    end

    def create
      authorize(:module, :projects_write?)
      @project = Projects::Project.new(project_params)
      if ActiveModel::Type::Boolean.new.cast(params[:assign_self]) && !project_params.key?(:owner_id)
        @project.owner_id = Current.user.id
      end
      template = Projects::ProjectTemplate.find_by(id: params[:template_id]) if params[:template_id].present?
      template&.build_into(@project)

      if @project.save
        ActivityLogger.log('project_created', subject: @project,
          details: ["Owner: #{@project.owner_id.presence || 'unassigned'}", ("From template #{template.name}" if template)].compact.join('; '))
        redirect_to(@project, notice: template ? "Project created with #{helpers.pluralize(template.task_count, 'task')} from #{template.name}." : 'Project created.')
      else
        @templates = Projects::ProjectTemplate.alphabetical
        render(:new, status: :unprocessable_entity)
      end
    end

    def edit
      authorize(@project)
    end

    def update
      authorize(@project)
      if @project.update(project_params)
        ActivityLogger.log('project_updated', subject: @project, details: "Owner: #{@project.owner_id.presence || 'unassigned'}")
        redirect_to(@project, notice: 'Project updated.')
      else
        render(:edit, status: :unprocessable_entity)
      end
    end

    def destroy
      authorize(@project)
      @project.destroy
      ActivityLogger.log('project_deleted', subject: @project)
      redirect_to(projects_projects_path, notice: 'Project deleted.')
    end

    # POST /projects/:id/save_template — keeps the outline (tasks, checklists, date offsets) for reuse.
    def save_template
      authorize(@project, :update?)
      name = params[:name].to_s.strip.presence || "#{@project.name} template"
      template = Projects::ProjectTemplate.capture(@project, name: name)
      if template.persisted?
        ActivityLogger.log('project_template_saved', subject: @project, details: name)
        redirect_to(@project, notice: "Saved “#{template.name}” as a template with #{helpers.pluralize(template.task_count, 'task')}.")
      else
        redirect_to(@project, alert: template.errors.full_messages.to_sentence)
      end
    end

    # POST /projects/:id/transition?event=start
    # Completing a project with unfinished tasks needs an explicit choice (open_tasks=finish|leave).
    def transition
      authorize(@project)
      event = params[:event]
      open_tasks = event == 'complete' ? @project.tasks.unfinished.count : 0
      if open_tasks.positive? && %w[finish leave].exclude?(params[:open_tasks])
        return redirect_to(@project, alert: "#{helpers.pluralize(open_tasks, 'task')} still open. Choose whether to finish them or leave them open.")
      end

      left = 0
      transitioned = @project.with_lock do
        if %w[start hold complete archive reopen].include?(event) && @project.public_send("may_#{event}?")
          left = finish_open_tasks(@project) if open_tasks.positive? && params[:open_tasks] == 'finish'
          @project.public_send("#{event}!")
        end
      end
      if transitioned
        ActivityLogger.log('project_transitioned', subject: @project, details: "Status: #{@project.status}")
        notice = "Project #{EVENT_PAST.fetch(event)}."
        notice += " #{helpers.pluralize(left, 'task')} could not be finished (still waiting on others)." if left.positive?
        redirect_to(@project, notice: notice)
      else
        redirect_to(@project, alert: "Cannot #{event} a #{@project.status.humanize.downcase} project.")
      end
    rescue ActiveRecord::RecordInvalid => error
      redirect_to(@project, alert: error.record.errors.full_messages.to_sentence)
    end

    private

    # Finishes what can be finished, waiting tasks last. Returns how many stayed open.
    def finish_open_tasks(project)
      remaining = project.tasks.unfinished.to_a
      5.times do
        progressed = remaining.select { |task| task.move_to!('done') }
        remaining -= progressed
        break if remaining.empty? || progressed.empty?
      end
      remaining.size
    end

    # Rows for the timeline: each task's bar as percentages of the project's span.
    def build_timeline(tasks)
      range = @project.timeline_range
      return { range: nil, rows: [], unscheduled: tasks } unless range

      first, last = range
      span = (last - first).to_i + 1
      scheduled, unscheduled = tasks.partition { |task| task.start_on || task.due_on }
      rows = scheduled.sort_by { |task| [task.start_on || task.due_on, task.due_on || task.start_on, task.id] }.map do |task|
        from = task.start_on || task.due_on
        to = task.due_on || task.start_on
        { task: task, left: ((from - first).to_i * 100.0 / span).round(2), width: [((to - from).to_i + 1) * 100.0 / span, 1.5].max.round(2) }
      end
      today = Date.current.between?(first, last) ? ((Date.current - first).to_i * 100.0 / span).round(2) : nil
      { range: range, rows: rows, unscheduled: unscheduled, today: today, months: month_marks(first, last, span) }
    end

    def month_marks(first, last, span)
      (first.beginning_of_month..last).select { |day| day.day == 1 || day == first }.map do |day|
        { label: day.strftime(day.month == 1 || day == first ? '%b %Y' : '%b'), left: [((day - first).to_i * 100.0 / span).round(2), 0].max }
      end
    end

    # Untrusted text must not become a spreadsheet formula when opened.
    def csv_safe(value)
      value.is_a?(String) && value.match?(/\A[=+\-@\t\r]/) ? "'#{value}" : value
    end

    # One grouped query for every card instead of a count per project.
    def preload_task_counts(projects)
      ids = projects.map { |p| p.id.to_s }
      grouped = Projects::Task.where(project_id: ids).group(:project_id, :status).count
      overdue = Projects::Task.overdue.where(project_id: ids).group(:project_id).count
      projects.each do |project|
        counts = Projects::Task::BOARD_STATUSES.index_with { |status| grouped[[project.id.to_s, status]].to_i }
        project.preload_task_stats(counts, overdue[project.id.to_s].to_i)
      end
    end

    def set_project
      @project = Projects::Project.find(params[:id])
    end

    def project_params
      permitted = params.require(:project).permit(:name, :description, :due_on, :start_on, :owner_id, :goal_id, member_ids: [])
      if permitted.key?(:member_ids)
        allowed = Projects::Project.available_people.pluck(:id)
        permitted[:member_ids] = permitted[:member_ids].filter_map { |id| Integer(id, exception: false) }.select { |id| allowed.include?(id) }
      end
      permitted
    end
  end
end
