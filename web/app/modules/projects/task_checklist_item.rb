# frozen_string_literal: true

module Projects
  class TaskChecklistItem < ApplicationRecord
    include TenantScoped

    self.table_name = 'task_checklist_items'
    LIMIT = 50

    belongs_to :task, class_name: 'Projects::Task'

    validates :title, presence: true, length: { maximum: 200 }
    validate :room_on_task, on: :create

    before_validation { self.title = title.to_s.strip }
    before_create { self.position = (task.checklist_items.maximum(:position) || -1) + 1 }

    private

    def room_on_task
      errors.add(:base, "A checklist holds at most #{LIMIT} items") if task && task.checklist_items.count >= LIMIT
    end
  end
end
