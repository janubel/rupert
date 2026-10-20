# frozen_string_literal: true

module Projects
  class TaskPolicy < ApplicationPolicy
    def create?
      module?('projects.write')
    end

    def update?
      module?('projects.write') && tenant?
    end

    def destroy?
      module?('projects.write') && tenant?
    end

    def transition?
      update?
    end

    def move?
      update?
    end
  end
end
