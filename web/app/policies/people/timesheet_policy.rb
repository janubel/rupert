# frozen_string_literal: true

module People
  class TimesheetPolicy < ApplicationPolicy
    def index?
      user&.can?('timesheets.read') || worker.present?
    end

    def show?
      tenant? && (user.can?('timesheets.read') || own?)
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
      tenant? && user&.can_review_timesheets? && record.employee.user_id != user.id
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

    def self.visible_to(user)
      scope = People::Timesheet.all
      return scope if user.can?('timesheets.read')
      worker = TimeClockService.worker_for(user, include_on_leave: true)
      worker ? scope.where(employee_id: worker.id) : scope.none
    end
  end
end
