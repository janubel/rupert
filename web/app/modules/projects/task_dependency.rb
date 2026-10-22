# frozen_string_literal: true

module Projects
  # task cannot start or finish until blocker is done.
  class TaskDependency < ApplicationRecord
    include TenantScoped

    self.table_name = 'task_dependencies'

    belongs_to :task, class_name: 'Projects::Task'
    belongs_to :blocker, class_name: 'Projects::Task'

    validates :blocker_id, uniqueness: { scope: :task_id }
    validate :distinct_tasks
    validate :no_cycle

    private

    def distinct_tasks
      errors.add(:blocker, 'cannot be the task itself') if blocker_id == task_id
    end

    # A chain that loops back would make every task in it unfinishable.
    def no_cycle
      return if blocker_id.blank? || task_id.blank? || blocker_id == task_id

      seen = Set.new
      queue = [blocker_id]
      while (id = queue.shift)
        next unless seen.add?(id)

        if id == task_id
          errors.add(:blocker, 'would make these tasks wait on each other')
          return
        end
        queue.concat(self.class.where(task_id: id).pluck(:blocker_id))
      end
    end
  end
end
