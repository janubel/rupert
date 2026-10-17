# frozen_string_literal: true

# Explicit operator action, never called by migrations or sign-in. Samples use
# the normal review workflow but cannot contribute hours to payroll/reports.
class DemoTimesheetProvisioner
  def self.call(user:, reviewer:, actor:, today: Date.current)
    raise Pundit::NotAuthorizedError unless actor&.active? && actor.can_manage_accounts? && actor.can?('timesheets.write') && (actor.super_admin? || actor.tenant_id == Current.tenant_id)
    raise ArgumentError, 'Choose an active staff account in this workspace.' unless user&.active? && user.employee? && user.tenant_id == Current.tenant_id
    unless reviewer&.active? && reviewer.tenant_id == Current.tenant_id && reviewer.id != user.id
      raise ArgumentError, 'Choose another active reviewer in this workspace.'
    end
    worker = TimeClockService.worker_for(user) || raise(ArgumentError, 'Link exactly one active staff profile first.')
    People::Timesheet.transaction do
      Tenant.where(id: Current.tenant_id).update_all('updated_at = updated_at')
      [2, 1].map do |weeks_ago|
        monday = today.beginning_of_week - weeks_ago.weeks
        existing = worker.timesheets.find_by(period_start: monday)
        if existing
          unless existing.demo? && existing.assigned_reviewer_id == reviewer.id
            raise ArgumentError, 'A different timesheet already uses this period; nothing was replaced.'
          end
          next existing
        end
        sheet = worker.timesheets.create!(period_start: monday, period_end: monday + 6, demo: true,
          assigned_reviewer: reviewer, notes: 'DEMO: Fictional sample hours for review practice. No work or payroll is represented.')
        hours = weeks_ago == 2 ? [8, 8, 8, 8, 8] : [8, 8, 6, 8, 8]
        hours.each_with_index do |value, day|
          sheet.entries.create!(worked_on: monday + day, hours: value, work_type: 'regular', notes: 'DEMO: Fictional retail shift for review practice.')
        end
        # DEMO: fictional credited sales (1% commission) and employee 50%-off
        # card redemptions (fixed bonus). Display figures only, never payroll.
        sales_cents = weeks_ago == 2 ? 120_000 : 96_000
        redemptions = weeks_ago == 2 ? 3 : 2
        sheet.update!(sales_cents: sales_cents, card_redemptions: redemptions)
        sheet.events.create!(user: actor, action: 'demo_created', details: { assigned_reviewer_id: reviewer.id, fictional: true })
        TimesheetWorkflow.new(user: actor).change(sheet, :submit)
        sheet
      end
    end
  end
end
