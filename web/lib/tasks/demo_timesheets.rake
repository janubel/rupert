# frozen_string_literal: true

namespace :timesheets do
  desc 'Create two submitted, payroll-excluded demo weeks for a staff member and assigned reviewer'
  task :demo, %i[employee_email workspace reviewer_email actor_email] => :environment do |_task, args|
    raise ArgumentError, 'Specify employee_email, workspace, reviewer_email and actor_email.' unless args.to_a.length == 4 && args.to_a.all?(&:present?)
    tenant = Tenant.find_by!(subdomain: args[:workspace], status: 'active')
    actor = User.find_by!(email: args[:actor_email].strip.downcase, tenant_id: tenant.id)
    Current.set(tenant: tenant, user: actor) do
      user = User.find_by!(email: args[:employee_email].strip.downcase, tenant_id: tenant.id)
      reviewer = User.find_by!(email: args[:reviewer_email].strip.downcase, tenant_id: tenant.id)
      sheets = DemoTimesheetProvisioner.call(user: user, reviewer: reviewer, actor: actor)
      puts JSON.generate(sheets.map { |s| { id: s.id, period: s.period_label, status: s.status, demo: s.demo?, hours: s.total_hours.to_s('F'), sales_cents: s.sales_cents, commission_cents: s.commission_cents, card_redemptions: s.card_redemptions, card_bonus_cents: s.card_bonus_cents, compensation_total_cents: s.compensation_total_cents, assigned_reviewer: s.assigned_reviewer.display_name } })
    end
  end
end
