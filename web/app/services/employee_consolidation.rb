# frozen_string_literal: true

# Explicit, tenant-local identity decisions. Never infer identity from an email:
# a shared mailbox can belong to several people. Original rows are retained.
class EmployeeConsolidation
  class Error < StandardError; end
  HISTORY = [People::Timesheet, People::LeaveBalance, People::LeaveRequest, People::PayRate, People::Payslip,
    EmployeeAccessGrant, EmployeeAppSession, EmployeeWorkReport, SquareTimecard].freeze
  HR_FIELDS = %w[user_id department_id position_id employee_number legal_name address date_of_birth hire_date
    termination_date emergency_contact_name emergency_contact_phone].freeze

  def self.call(primary_id:, duplicate_ids:, reason:)
    raise Error, 'Record why these profiles are the same person (up to 2,000 characters).' if reason.to_s.strip.blank? || reason.to_s.length > 2000
    ids = Array(duplicate_ids).map(&:to_s).uniq - [primary_id.to_s]
    raise Error, 'Select at least one duplicate profile.' if ids.empty?
    People::Employee.transaction do
      raise ActiveRecord::RecordNotFound unless Tenant.where(id: Current.tenant_id).update_all('updated_at = updated_at') == 1

      primary = People::Employee.lock.find(primary_id)
      duplicates = ids.map { |id| People::Employee.lock.find(id) }
      records = [primary, *duplicates]
      original_user_ids = records.map(&:user_id)
      check_conflicts!(records)
      attrs = HR_FIELDS.to_h { |field| [field, records.map { |r| r.public_send(field) }.find(&:present?)] }
      attrs['employment_type'] = records.map(&:employment_type).find { |type| type != 'unspecified' } || 'unspecified'
      attrs['notes'] = records.map(&:notes).select(&:present?).uniq.join("\n\n").presence
      duplicates.each do |duplicate|
        duplicate.update_columns(user_id: nil, employee_number: nil, merged_into_id: primary.id, merged_at: Time.current,
          merge_snapshot: duplicate.attributes.except('merge_snapshot').to_json, updated_at: Time.current)
        EmployeeSourceIdentity.where(employee_id: duplicate.id).update_all(employee_id: primary.id, updated_at: Time.current)
        HISTORY.each { |model| model.where(employee_id: duplicate.id).update_all(employee_id: primary.id) }
        ClockShift.where(employee_id: duplicate.id).update_all(employee_id: primary.id, employee_key: primary.id.to_s)
        People::Department.where(manager_id: duplicate.id).update_all(manager_id: primary.id)
        # Move previous tombstones too, keeping old bookmarks a single hop away.
        People::Employee.unscoped.where(tenant_id: Current.tenant_id, merged_into_id: duplicate.id).update_all(merged_into_id: primary.id)
      end
      primary.update!(attrs)
      EmployeeAccessGrant.where(employee_id: primary.id, used_at: nil).update_all(used_at: Time.current)
      EmployeeAppSession.where(employee_id: primary.id, revoked_at: nil).update_all(revoked_at: Time.current)
      ActivityLog.create!(action: 'employee_profiles_consolidated', user: Current.user, actor_name: Current.user&.display_name || 'system',
        subject_type: 'People::Employee', subject_id: primary.id.to_s, subject_label: primary.name,
        details: { original_ids: records.map(&:id), original_user_ids: original_user_ids, reason: reason.to_s.strip }.to_json)
      primary
    end
  end

  def self.check_conflicts!(records)
    HR_FIELDS.each do |field|
      raise Error, "Conflicting #{field.humanize.downcase}; review the HR records first." if records.map { |r| r.public_send(field).presence }.compact.uniq.size > 1
    end
    raise Error, 'Employment statuses differ; review the HR records first.' unless records.map(&:status).uniq.one?
    types = records.map(&:employment_type).reject { |v| v == 'unspecified' }.uniq
    raise Error, 'Employment types differ; review the HR records first.' if types.size > 1
    ids = records.map(&:id)
    sheets = People::Timesheet.where(employee_id: ids).to_a
    raise Error, 'Overlapping timesheets must be reviewed first.' if sheets.combination(2).any? { |a, b| a.employee_id != b.employee_id && a.period_start <= b.period_end && b.period_start <= a.period_end }
    imported = SquareTimecard.counted.where('payable_seconds > 0').where(employee_id: ids).to_a
    raise Error, 'Overlapping Square timecards must be reviewed first.' if imported.combination(2).any? { |a, b| a.employee_id != b.employee_id && a.started_at < b.ended_at && b.started_at < a.ended_at }
    entries = People::TimesheetEntry.joins(:timesheet).where(timesheets: { employee_id: ids }, work_type: %w[regular overtime]).includes(:timesheet).to_a
    raise Error, 'Square history and local timesheet dates must be reviewed first.' if imported.any? { |card| entries.any? { |entry| entry.timesheet.employee_id != card.employee_id && entry.worked_on.in_time_zone < card.ended_at && (entry.worked_on + 1).in_time_zone > card.started_at } }
    shifts = ClockShift.where(employee_id: ids).to_a
    raise Error, 'Square history and clock shifts overlap; review them first.' if imported.any? { |card| shifts.any? { |shift| shift.employee_id != card.employee_id && shift.started_at < card.ended_at && (!shift.ended_at || shift.ended_at > card.started_at) } }
    raise Error, 'Overlapping shifts must be reviewed first.' if shifts.combination(2).any? { |a, b| a.employee_id != b.employee_id && (!a.ended_at || b.started_at < a.ended_at) && (!b.ended_at || a.started_at < b.ended_at) }
    raise Error, 'Pay rates on multiple profiles must be reviewed first.' if People::PayRate.where(employee_id: ids).distinct.count(:employee_id) > 1
    [[People::LeaveBalance, %i[leave_type year]], [People::Payslip, [:pay_run_id]]].each do |model, keys|
      raise Error, 'Duplicate leave balances or payslips must be reviewed first.' if model.where(employee_id: ids).group(*keys).having('COUNT(*) > 1').exists?
    end
  end
  private_class_method :check_conflicts!
end
