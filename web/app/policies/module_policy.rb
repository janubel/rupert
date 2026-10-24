# frozen_string_literal: true

# Generic gate for module-level pages (index/sync/etc.) that aren't tied to a
# specific record. Authorize with `authorize :module, :sales_read?` and define
# a method per permission.
class ModulePolicy < ApplicationPolicy
  %i[
    marketing_read
    marketing_write
    marketing_review
    marketing_contacts
    marketing_discounts
    dashboard_read
    sales_read
    sales_write
    customers_read
    customers_write
    inventory_read
    inventory_write
    reconcile_read
    reconcile_write
    reports_read
    reports_write
    ledger_read
    ledger_write
    projects_read
    projects_write
    alerts_read
    alerts_write
    sync_read
    sync_write
    settings_read
    settings_write
    system_read
    system_write
    users_read
    users_write
    purchasing_read
    purchasing_write
    finance_read
    finance_write
    uploads_read
    uploads_write
    hr_read
    hr_write
    timesheets_read
    timesheets_write
    leave_read
    leave_write
    payroll_read
    payroll_write
    tax_read
    tax_write
  ].each do |perm|
    define_method("#{perm}?") { module?(perm.to_s.tr('_', '.')) }
  end

  # Add, change and remove planned shifts. hr.write still covers it, so people granted HR editing keep it.
  def schedule_write? = module?('schedule.write') || module?('hr.write')
  def schedule_read? = hr_read? || schedule_write?
end
