# frozen_string_literal: true

module Projects
  class TaskDependenciesController < TaskChildrenController
    # Only people who plan work (projects.write) decide what waits on what.
    before_action { authorize(:module, :projects_write?) }

    def create
      blocker = policy_scope(Projects::Task).find_by(id: params.dig(:dependency, :blocker_id))
      return back(alert: 'Choose a task from the list.', anchor: 'waiting') unless blocker

      link = @task.dependencies.new(blocker: blocker)
      if link.save
        ActivityLogger.log('task_dependency_added', subject: @task, details: "Waits on ##{blocker.id} #{blocker.title}")
        back(notice: 'Dependency added.', anchor: 'waiting')
      else
        failed(link, anchor: 'waiting')
      end
    end

    def destroy
      link = @task.dependencies.find(params[:id])
      link.destroy
      ActivityLogger.log('task_dependency_removed', subject: @task, details: "No longer waits on ##{link.blocker_id}")
      back(notice: 'Dependency removed.', anchor: 'waiting')
    end
  end
end
