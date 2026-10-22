# frozen_string_literal: true

module Projects
  # Someone who works on a project besides its owner. Membership groups people
  # and decides who hears about project activity; it grants no access.
  class ProjectMember < ApplicationRecord
    include TenantScoped
    include ProjectsPeople

    self.table_name = 'project_members'

    belongs_to :project, class_name: 'Projects::Project'
    belongs_to :user

    validates :user_id, uniqueness: { scope: :project_id }
    validate { validate_project_person(:user_id) }
  end
end
