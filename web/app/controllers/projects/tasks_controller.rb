# frozen_string_literal: true

module Projects
  class TasksController < AuthenticatedController
    before_action :set_task, only: %i[update destroy transition move]

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
      @assignees = assignee_lookup

      if @view == 'board'
        tasks = @scope.by_priority.limit(BOARD_LIMIT).to_a
        @columns = Projects::Task::BOARD_STATUSES.index_with { |s| tasks.select { |t| t.status == s } }
      else
        @pagy, @tasks = pagy(@scope.by_priority, items: 30)
      end
    end

    def create
      authorize(:module, :projects_write?)
      @project = Projects::Project.find_by(id: params[:project_id])
      @task = (@project ? @project.tasks : Projects::Task).new(task_params)
      @task.assignee_id = Current.user.id if params[:assign_self]

      if @task.save
        redirect_back(fallback_location: @project || projects_tasks_path, notice: 'Task added.')
      else
        redirect_back(fallback_location: @project || projects_tasks_path, alert: @task.errors.full_messages.join(', '))
      end
    end

    def update
      authorize(@task)
      if @task.update(task_params)
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
      redirect_back(fallback_location: project || projects_tasks_path, notice: 'Task deleted.')
    end

    # POST /tasks/:id/transition?event=start|finish|block|reopen
    def transition
      authorize(@task)
      event = params[:event]
      if %w[start finish block reopen unstart].include?(event) && @task.public_send("may_#{event}?")
        @task.send("#{event}!")
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
    def assignee_lookup
      ids = Projects::Task.where.not(assignee_id: nil).distinct.pluck(:assignee_id)
      User.where(id: ids).to_h { |u| [u.id.to_s, u.display_name] }
    end

    def task_params
      params.require(:task).permit(:title, :description, :priority, :due_on, :project_id)
    end
  end
end
