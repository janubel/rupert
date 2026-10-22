# frozen_string_literal: true

module Projects
  # Shared by the controllers for what hangs off a task (comments, checklist,
  # dependencies, time, files). Whoever may edit the task may change them, so an
  # employee can work only on tasks assigned to them and read-only people on none.
  class TaskChildrenController < AuthenticatedController
    before_action :set_task

    private

    def set_task
      @task = policy_scope(Projects::Task).find(params[:task_id])
      authorize(@task, :update?)
    end

    def back(anchor: nil, **message)
      redirect_to(projects_task_path(@task, anchor: anchor), **message)
    end

    def failed(record, anchor: nil)
      back(alert: record.errors.full_messages.to_sentence, anchor: anchor)
    end
  end
end
