# frozen_string_literal: true

module Projects
  class TaskPolicy < ApplicationPolicy
    def index?
      user&.active? && (user.employee? ? module?('tasks.self') : module?('projects.read'))
    end

    def create?
      user&.active? && !user.employee? && module?('projects.write')
    end

    def update?
      return false unless user&.active? && tenant?
      return user.tenant_id.present? && module?('tasks.self') && record.assignee_id.to_s == user.id.to_s if user.employee?

      module?('projects.write')
    end

    def destroy?
      create? && tenant?
    end

    def transition?
      update?
    end

    def move?
      update?
    end

    class Scope
      def initialize(user, scope)
        @user = user
        @scope = scope
      end

      def resolve
        return @scope.none unless @user&.active? && (@user.super_admin? || @user.tenant_id.present?)

        tasks = @user.super_admin? ? @scope : @scope.where(tenant_id: @user.tenant_id)
        if @user.employee?
          @user.can?('tasks.self') ? tasks.assigned_to(@user.id) : tasks.none
        elsif @user.can?('projects.read') || @user.can?('projects.write')
          tasks
        else
          tasks.none
        end
      end
    end
  end
end
