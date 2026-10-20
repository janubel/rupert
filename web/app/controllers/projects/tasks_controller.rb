# frozen_string_literal: true

module Projects
  class TasksController < AuthenticatedController
    before_action :set_task, only: %i[update destroy transition move]
    rescue_from ActiveRecord::RecordInvalid, with: :invalid_task

    BOARD_LIMIT = 250

    # Cross-project work, as a drag-and-drop board (default) or a sortable list.
    def index
      authorize(:module, :projects_read?)
      @view = params[:view] == 'list' ? 'list' : 'board'
      @scope = filtered_tasks
      @counts = Projects::Task.group(:status).count
      @open_count = @counts.slice('todo', 'in_progress', 'blocked').values.sum
      @done_count = @counts['done'].to_i
      @blocked_count = @counts['blocked'].to_i
      @overdue_count = Projects::Task.overdue.count
      @mine_count = Projects::Task.assigned_to(Current.user.id).where.not(status: 'done').count
      @projects = Projects::Project.where.not(status: 'archived').order(:name)

      if @view == 'board'
        @board_total = @scope.count
        tasks = @scope.by_priority.limit(BOARD_LIMIT).to_a
        @columns = Projects::Task::BOARD_STATUSES.index_with { |s| tasks.select { |t| t.status == s } }
      else
        @pagy, @tasks = pagy(@scope.by_priority, items: 30)
      end
      @assignees = assignee_lookup(tasks || @tasks)
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
        redirect_back(fallback_location: @project || projects_tasks_path, notice: 'Task added.')
      else
        redirect_back(fallback_location: @project || projects_tasks_path, alert: @task.errors.full_messages.join(', '))
      end
    end

    def update
      authorize(@task)
      if @task.update(task_params)
        ActivityLogger.log('task_updated', subject: @task, details: "Assignee: #{@task.assignee_id.presence || 'unassigned'}")
        redirect_back(fallback_location: @task.project || projects_tasks_path, notice: 'Task updated.')
      else
        redirect_back(fallback_location: @task.project || projects_tasks_path,
          alert: @task.errors.full_messages.join(', '))
      end
    end

    def destroy
      authorize(@task)
      project = @task.project
      @task.destroy
      ActivityLogger.log('task_deleted', subject: @task)
      redirect_back(fallback_location: project || projects_tasks_path, notice: 'Task deleted.')
    end

    # POST /tasks/:id/transition?event=start|finish|block|reopen
    def transition
      authorize(@task)
      event = params[:event]
      transitioned = @task.with_lock do
        if %w[start finish block reopen unstart].include?(event) && @task.public_send("may_#{event}?")
          @task.public_send("#{event}!")
        end
      end
      if transitioned
        ActivityLogger.log('task_transitioned', subject: @task, details: "Status: #{@task.status}")
        redirect_back(fallback_location: @task.project || projects_tasks_path, notice: "Task #{event}ed.")
      else
        redirect_back(fallback_location: @task.project || projects_tasks_path,
          alert: "Cannot #{event} a #{@task.status} task.")
      end
    end

    # POST /tasks/:id/move?status=in_progress — used by the board's drag and drop.
    def move
      authorize(@task)
      moved = @task.move_to!(params[:status].to_s)
      ActivityLogger.log('task_moved', subject: @task, details: "Status: #{@task.status}") if moved
      respond_to do |format|
        format.json do
          if moved || @task.status == params[:status].to_s
            render(json: { id: @task.id, status: @task.status, done_at: @task.completed_at })
          else
            render(json: { error: "Cannot move a #{@task.status} task to #{params[:status]}." },
              status: :unprocessable_entity)
          end
        end
        format.html do
          redirect_back(fallback_location: projects_tasks_path,
                        **(moved ? { notice: 'Task moved.' } : { alert: "Cannot move to #{params[:status]}." }))
        end
      end
    end

    private

    def invalid_task(error)
      message = error.record.errors.full_messages.to_sentence
      respond_to do |format|
        format.json { render(json: { error: message }, status: :unprocessable_entity) }
        format.html { redirect_back(fallback_location: projects_tasks_path, alert: message) }
      end
    end

    def set_task
      @task = Projects::Task.find(params[:id])
    end

    def filtered_tasks
      tasks = Projects::Task.includes(:project)
      tasks = tasks.search(params[:q]) if params[:q].present?
      tasks = tasks.where(priority: params[:priority]) if params[:priority].in?(Projects::Task::PRIORITIES)
      tasks = tasks.where(project_id: params[:project_id]) if params[:project_id].present?
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
      params.require(:task).permit(:title, :description, :priority, :due_on, :project_id, :assignee_id)
    end
  end
end
