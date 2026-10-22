# frozen_string_literal: true

require 'csv'

module Projects
  class TasksController < AuthenticatedController
    before_action :set_task, only: %i[show update destroy transition move approved_request]
    rescue_from ActiveRecord::RecordInvalid, with: :invalid_task

    BOARD_LIMIT = 250
    EXPORT_LIMIT = 50_000
    VIEWS = %w[board list calendar].freeze

    # Cross-project work, as a drag-and-drop board (default), a sortable list or a month calendar.
    def index
      authorize(Projects::Task, :index?)
      @view = params[:view].presence_in(VIEWS) || 'board'
      @scope = filtered_tasks
      @counts = visible_tasks.group(:status).count
      @open_count = @counts.slice('todo', 'in_progress', 'blocked').values.sum
      @done_count = @counts['done'].to_i
      @blocked_count = @counts['blocked'].to_i
      @overdue_count = visible_tasks.overdue.count
      @mine_count = visible_tasks.assigned_to(Current.user.id).where.not(status: 'done').count
      @projects = Projects::Project.where.not(status: 'archived').order(:name)
      @projects = @projects.where(visible_tasks.where('tasks.project_id = projects.id').arel.exists) if Current.user.employee?

      shown = case @view
              when 'board' then load_board
              when 'calendar' then load_calendar
              else
                @pagy, @tasks = pagy(:offset, @scope.by_board_order.includes(:checklist_items), limit: 30)
                @tasks
              end
      @assignees = assignee_lookup(shown)
    end

    def show
      authorize(@task)
      @comments = @task.comments.includes(:user)
      @history = ActivityLog.for_subject('Projects::Task', @task.id).recent(25)
      @people = people_on(@task, @comments)
      @waiting_on = @task.open_blockers.to_a
      @can_edit = policy(@task).update?
      @can_manage = Current.user.can?('projects.write')
    end

    # Retained approvals are bound to the executed task, independently of chat lifetime.
    def approved_request
      authorize(@task, :show?)
      @approval = TeamChat::Approval.find_by!(public_id: params[:approval_id], state: 'done')
      result = @approval.events.find_by(kind: 'executed')&.details&.dig('result', 'id')
      unless %w[create_task update_task].include?(@approval.proposal['tool']) && result.to_s == @task.id.to_s
        raise ActiveRecord::RecordNotFound
      end
      response.headers['Cache-Control'] = 'no-store'
      @show_original = @approval.original_request_visible_to?(Current.user)
    end

    def export
      authorize(Projects::Task, :index?)
      tasks = filtered_tasks.by_priority.limit(EXPORT_LIMIT).to_a
      people = assignee_lookup(tasks)
      logged = Projects::TaskTimeEntry.where(task_id: tasks.map(&:id)).group(:task_id).sum(:minutes)
      csv = CSV.generate do |out|
        out << ['ID', 'Title', 'Project', 'Status', 'Priority', 'Assignee', 'Start', 'Due', 'Labels', 'Estimate (h)', 'Logged (h)',
                'Repeats', 'Blocked reason', 'Completed', 'Notes']
        tasks.each do |task|
          out << [task.id, task.title, task.project&.name, task.status, task.priority, people[task.assignee_id.to_s], task.start_on,
                  task.due_on, task.labels.join('; '), task.estimate_hours, (logged[task.id].to_i / 60.0).round(2),
                  Projects::Task::RECURRENCES[task.recurrence], task.blocked_reason, task.completed_at&.to_date,
                  task.description].map { |cell| csv_safe(cell) }
        end
      end
      log_export('Tasks CSV', "#{tasks.size} rows")
      send_data(csv, filename: "tasks-#{Date.current.iso8601}.csv", type: 'text/csv; charset=utf-8')
    end

    def create
      authorize(:module, :projects_write?)
      @project = Projects::Project.find(params[:project_id]) if params[:project_id].present?
      @task = (@project ? @project.tasks : Projects::Task).new(task_params)
      if ActiveModel::Type::Boolean.new.cast(params[:assign_self]) && !task_params.key?(:assignee_id)
        @task.assignee_id = Current.user.id
      end

      if @task.save
        ActivityLogger.log('task_created', subject: @task, details: "Assignee: #{@task.assignee_id.presence || 'unassigned'}")
        TaskNotifier.assigned(@task)
        redirect_back(fallback_location: @project || projects_tasks_path, notice: 'Task added.')
      else
        redirect_back(fallback_location: @project || projects_tasks_path, alert: @task.errors.full_messages.join(', '))
      end
    end

    def update
      previous_assignee = nil
      saved = @task.with_lock do
        authorize(@task)
        previous_assignee = @task.assignee_id
        @task.update(task_params)
      end
      if saved
        changed = @task.saved_changes.keys - %w[updated_at]
        ActivityLogger.log('task_updated', subject: @task,
          details: ["Assignee: #{@task.assignee_id.presence || 'unassigned'}", ("Changed: #{changed.to_sentence}" if changed.any?)].compact.join('; '))
        TaskNotifier.assigned(@task) if @task.assignee_id.to_s != previous_assignee.to_s
        redirect_back(fallback_location: task_fallback_location, notice: 'Task updated.')
      else
        redirect_back(fallback_location: task_fallback_location, alert: @task.errors.full_messages.join(', '))
      end
    end

    def destroy
      authorize(@task)
      project = @task.project
      @task.destroy
      ActivityLogger.log('task_deleted', subject: @task)
      redirect_to(project || projects_tasks_path, notice: 'Task deleted.')
    end

    # POST /tasks/:id/transition?event=start|finish|block|reopen&reason=…
    def transition
      event = params[:event]
      transitioned = @task.with_lock do
        authorize(@task)
        if %w[start finish block reopen unstart].include?(event) && @task.public_send("may_#{event}?")
          if event == 'block'
            @task.block_with_reason!(params[:reason])
          else
            @task.public_send("#{event}!")
          end
        end
      end
      if transitioned
        ActivityLogger.log('task_transitioned', subject: @task,
          details: ["Status: #{@task.status}", (@task.blocked_reason if @task.blocked?)].compact.join('; '))
        TaskNotifier.blocked(@task) if @task.blocked?
        redirect_back(fallback_location: task_fallback_location, notice: "Task #{event}ed.")
      else
        redirect_back(fallback_location: task_fallback_location, alert: @task.refusal_for(event))
      end
    end

    # POST /tasks/:id/move?status=in_progress — used by the board's drag and drop.
    # ordered_ids is the destination column's cards, top to bottom, and also sets their hand-placed order.
    def move
      moved = @task.with_lock do
        authorize(@task)
        @task.move_to!(params[:status].to_s)
      end
      if moved
        ActivityLogger.log('task_moved', subject: @task, details: "Status: #{@task.status}")
        TaskNotifier.blocked(@task) if @task.blocked?
      end
      placed = place_in_order(params[:ordered_ids])
      respond_to do |format|
        format.json do
          if moved || placed || @task.status == params[:status].to_s
            render(json: { id: @task.id, status: @task.status, done_at: @task.completed_at })
          else
            render(json: { error: move_refusal }, status: :unprocessable_entity)
          end
        end
        format.html do
          redirect_back(fallback_location: projects_tasks_path,
                        **(moved ? { notice: 'Task moved.' } : { alert: move_refusal }))
        end
      end
    end

    private

    # Names for the people who appear on this task only; staff never get a roster.
    def people_on(task, comments)
      ids = [task.assignee_id, task.project&.owner_id, *comments.map(&:user_id), *task.time_entries.map(&:user_id),
             *task.attachments.map(&:user_id)].compact.map(&:to_s).uniq
      User.where(tenant_id: Current.tenant_id, id: ids).to_h { |user| [user.id.to_s, user.display_name] }
    end

    def load_board
      @board_total = @scope.count
      tasks = @scope.by_board_order.includes(:checklist_items).limit(BOARD_LIMIT).to_a
      @columns = Projects::Task::BOARD_STATUSES.index_with { |s| tasks.select { |t| t.status == s } }
      tasks
    end

    def load_calendar
      first = parse_month(params[:month])
      @month = first
      @calendar_days = (first.beginning_of_week(:monday)..first.end_of_month.end_of_week(:monday)).to_a
      tasks = @scope.where(due_on: @calendar_days.first..@calendar_days.last).by_priority.limit(1000).to_a
      @calendar_tasks = tasks.group_by(&:due_on)
      @undated_count = @scope.where(due_on: nil).unfinished.count
      tasks
    end

    def parse_month(text)
      Date.strptime(text.to_s, '%Y-%m').beginning_of_month
    rescue ArgumentError
      Date.current.beginning_of_month
    end

    # Saves the hand-placed order of the cards the person could see, top to bottom.
    def place_in_order(ids)
      list = Array(ids).filter_map { |id| Integer(id, exception: false) }.first(BOARD_LIMIT)
      return false if list.empty?

      tasks = visible_tasks.where(id: list).index_by(&:id)
      changed = false
      Projects::Task.transaction do
        list.each_with_index do |id, index|
          task = tasks[id]
          next unless task && policy(task).update? && task.position != index

          task.update_columns(position: index)
          changed = true
        end
      end
      changed
    end

    def move_refusal
      return @task.refusal_for(params[:status] == 'done' ? 'finish' : 'start') if @task.open_blockers.any? && %w[in_progress done].include?(params[:status])

      "Cannot move a #{@task.status.humanize.downcase} task to #{params[:status].to_s.humanize.downcase}."
    end

    def invalid_task(error)
      message = error.record.errors.full_messages.to_sentence
      respond_to do |format|
        format.json { render(json: { error: message }, status: :unprocessable_entity) }
        format.html { redirect_back(fallback_location: projects_tasks_path, alert: message) }
      end
    end

    def set_task
      @task = visible_tasks.find(params[:id])
    end

    def visible_tasks
      policy_scope(Projects::Task)
    end

    def task_fallback_location
      Current.user.employee? ? projects_tasks_path : (@task.project || projects_tasks_path)
    end

    def filtered_tasks
      tasks = visible_tasks.includes(:project)
      tasks = tasks.search(params[:q]) if params[:q].present?
      tasks = tasks.where(priority: params[:priority]) if params[:priority].in?(Projects::Task::PRIORITIES)
      tasks = tasks.where(project_id: params[:project_id]) if params[:project_id].present?
      tasks = tasks.with_label(params[:label]) if params[:label].present?
      tasks = tasks.assigned_to(Current.user.id) if params[:mine] == '1'
      tasks = tasks.overdue if params[:due] == 'overdue'
      tasks = tasks.due_within(7) if params[:due] == 'week'
      if params[:status].in?(Projects::Task.aasm.states.map { |s| s.name.to_s })
        tasks = tasks.where(status: params[:status])
      end
      tasks
    end

    # id => display name, for the tenant's people, so cards can show an assignee.
    def assignee_lookup(tasks)
      ids = tasks.filter_map(&:assignee_id).uniq
      User.where(tenant_id: Current.tenant_id, id: ids).to_h { |u| [u.id.to_s, u.display_name] }
    end

    def task_params
      return params.require(:task).permit(:title, :description) if Current.user.employee?

      params.require(:task).permit(:title, :description, :priority, :due_on, :start_on, :project_id, :assignee_id,
        :labels_text, :recurrence, :estimate_hours)
    end

    # Untrusted text must not become a spreadsheet formula when opened.
    def csv_safe(value)
      value.is_a?(String) && value.match?(/\A[=+\-@\t\r]/) ? "'#{value}" : value
    end
  end
end
