# frozen_string_literal: true

module Projects
  class TaskComment < ApplicationRecord
    include TenantScoped

    self.table_name = 'task_comments'
    MAX_LENGTH = 5000

    belongs_to :task, class_name: 'Projects::Task'
    belongs_to :user, optional: true

    validates :body, presence: true, length: { maximum: MAX_LENGTH }
    before_validation { self.body = body.to_s.strip }
  end
end
