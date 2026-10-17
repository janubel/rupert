# frozen_string_literal: true

module People
  class TimesheetPolicy < ApplicationPolicy
    def index?
      user&.can?('timesheets.read') || worker.present? || self.class.assigned_demos(user).exists?
    end

    def show?
      tenant? && (user.can?('timesheets.read') || own? || assigned_demo?)
    end

    def create?
      user&.can?('timesheets.write') || (user&.active? && TimeClockService.worker_for(user).present?)
    end
    alias new? create?
    def update?
      tenant? && (user.can?('timesheets.write') || own?)
    end
    alias edit? update?
    alias destroy? update?
    alias submit? update?
    alias add_entry? update?
    alias update_entry? update?
    alias remove_entry? update?
    alias import_shifts? update?
    def approve?
      tenant? && user&.active? && (user.can_review_timesheets? || assigned_demo?) && record.employee.user_id != user.id
    end
    alias reject? approve?
    def reopen?
      tenant? && (user.can?('timesheets.write') || (own? && record.rejected?))
    end

    def worker
      TimeClockService.worker_for(user, include_on_leave: true) if user&.active?
    end

    def own?
      worker && record.employee_id == worker.id
    end

    def assigned_demo?
      record.respond_to?(:demo?) && record.demo? && record.assigned_reviewer_id == user&.id && user&.active? && record.tenant_id == user.tenant_id
    end

    def self.assigned_demos(user)
      return People::Timesheet.none unless user&.active?

      People::Timesheet.where(tenant_id: user.tenant_id, demo: true, assigned_reviewer_id: user.id)
    end

    def self.visible_to(user)
      scope = People::Timesheet.all
      return scope if user.can?('timesheets.read')
      worker = TimeClockService.worker_for(user, include_on_leave: true)
      own = worker ? scope.where(employee_id: worker.id) : scope.none
      own.or(assigned_demos(user))
    end
  end
end
