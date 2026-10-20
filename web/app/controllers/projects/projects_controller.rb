# frozen_string_literal: true

module Projects
  class ProjectsController < AuthenticatedController
    before_action :set_project, only: %i[show edit update destroy transition]

    STATUS_FILTERS = %w[planned active on_hold completed archived].freeze

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
      @pagy, @projects = pagy(scope, items: 18)
      @status_counts = Projects::Project.group(:status).count
      @overdue_tasks = Projects::Task.overdue.count
      @due_this_week = Projects::Task.due_within(7).count
      @open_tasks = Projects::Task.open.count + Projects::Task.where(status: 'blocked').count
      preload_task_counts(@projects)
    end

    def show
      authorize(@project)
      @board_total = @project.tasks.count
      tasks = @project.tasks.by_priority.limit(TasksController::BOARD_LIMIT).to_a
      @columns = Projects::Task::BOARD_STATUSES.index_with { |s| tasks.select { |t| t.status == s } }
      @assignees = User.where(tenant_id: Current.tenant_id, id: tasks.filter_map(&:assignee_id).uniq).to_h { |u| [u.id.to_s, u.display_name] }
    end

    def new
      authorize(:module, :projects_write?)
      @project = Projects::Project.new
    end

    def create
      authorize(:module, :projects_write?)
      @project = Projects::Project.new(project_params)
      if ActiveModel::Type::Boolean.new.cast(params[:assign_self]) && !project_params.key?(:owner_id)
        @project.owner_id = Current.user.id
      end

      if @project.save
        ActivityLogger.log('project_created', subject: @project, details: "Owner: #{@project.owner_id.presence || 'unassigned'}")
        redirect_to(@project, notice: 'Project created.')
      else
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

    # POST /projects/:id/transition?event=start
    def transition
      authorize(@project)
      event = params[:event]
      transitioned = @project.with_lock do
        if %w[start hold complete archive].include?(event) && @project.public_send("may_#{event}?")
          @project.public_send("#{event}!")
        end
      end
      if transitioned
        ActivityLogger.log('project_transitioned', subject: @project, details: "Status: #{@project.status}")
        redirect_to(@project, notice: "Project #{event}d.")
      else
        redirect_to(@project, alert: "Cannot #{event} a #{@project.status} project.")
      end
    rescue ActiveRecord::RecordInvalid => error
      redirect_to(@project, alert: error.record.errors.full_messages.to_sentence)
    end

    private

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
      params.require(:project).permit(:name, :description, :due_on, :owner_id)
    end
  end
end
