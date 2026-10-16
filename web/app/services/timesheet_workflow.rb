# frozen_string_literal: true

# Both browser and mobile clients use this transaction boundary. The tenant
# writer lock also serializes overlapping periods and aggregate daily hours
# on SQLite, where SELECT FOR UPDATE cannot serialize writers.
class TimesheetWorkflow
  class Error < StandardError; end

  def initialize(user: Current.user)
    @user = user
  end

  def create(attributes)
    serialize do
      check!(People::Timesheet.new, :create?)
      attrs = attributes.to_h.symbolize_keys.slice(:employee_id, :period_start, :period_end, :notes)
      attrs[:employee_id] = worker!.id unless @user.can?('timesheets.write')
      sheet = People::Timesheet.create!(attrs)
      audit(sheet, 'created')
      sheet
    end
  end

  def change(sheet, action, attributes = {})
    serialize do
      sheet.reload
      check!(sheet, "#{action}?")
      attrs = attributes.to_h.symbolize_keys
      case action.to_s
      when 'update'
        draft!(sheet)
        permitted = attrs.slice(:period_start, :period_end, :notes)
        sheet.update!(permitted)
      when 'destroy'
        draft!(sheet)
        raise Error, 'Timesheets with submission history must be retained.' if sheet.events.where(action: %w[submit approve reject reopen]).exists?
        sheet.destroy!
        ActivityLogger.log('timesheet_deleted', subject: sheet)
        next sheet
      when 'add_entry', 'update_entry', 'remove_entry'
        draft!(sheet)
        entry = action.to_s == 'add_entry' ? sheet.entries.new : sheet.entries.find(attrs[:entry_id])
        before = entry.attributes.slice('worked_on', 'hours', 'work_type', 'notes')
        action.to_s == 'remove_entry' ? entry.destroy! : entry.update!(attrs.slice(:worked_on, :hours, :work_type, :notes))
        attrs = { entry_id: entry.id, before: before, after: entry.attributes.slice('worked_on', 'hours', 'work_type', 'notes') }
      when 'submit'
        draft!(sheet)
        raise Error, 'Add at least one entry before submitting.' unless sheet.entries.exists?
        raise Error, 'This employee is no longer active.' unless sheet.employee.active?
        validate_imports!(sheet)
        sheet.update!(submitted_at: Time.current, reviewed_by: nil, reviewed_at: nil, review_note: nil)
        sheet.submit!
      when 'approve', 'reject'
        raise Error, 'Only submitted timesheets can be reviewed.' unless sheet.submitted?
        # Existing integrations may omit a note; the web and app show an optional review comment.
        sheet.update!(reviewed_by: @user.id, reviewed_at: Time.current, review_note: attrs[:review_note].to_s.strip.presence)
        sheet.public_send("#{action}!")
        attrs = attrs.slice(:review_note)
      when 'reopen'
        raise Error, 'Only approved or rejected timesheets can be reopened.' unless sheet.approved? || sheet.rejected?
        raise Error, 'This timesheet is included in payroll. Remove or regenerate that payslip before reopening.' if sheet.payroll_locked?
        sheet.reopen!
        sheet.update!(submitted_at: nil, reviewed_by: nil, reviewed_at: nil, review_note: nil)
      when 'import_shifts'
        draft!(sheet)
        import_shifts(sheet)
        attrs = {}
      else
        raise Error, 'Unsupported timesheet action.'
      end
      audit(sheet, action.to_s, attrs)
      sheet
    end
  end

  private

  def serialize
    raise Pundit::NotAuthorizedError unless @user&.active? && Current.tenant&.status == 'active' &&
      (@user.super_admin? || @user.tenant_id == Current.tenant_id)
    People::Timesheet.transaction do
      Tenant.where(id: Current.tenant_id).update_all('updated_at = updated_at')
      yield
    end
  end

  def check!(sheet, action)
    raise Pundit::NotAuthorizedError unless People::TimesheetPolicy.new(@user, sheet).public_send(action)
  end

  def worker!
    TimeClockService.worker_for(@user) || raise(Error, 'Ask an administrator to link one active employee record to your account.')
  end

  def draft!(sheet)
    raise Error, 'Only draft timesheets can be edited.' unless sheet.draft?
  end

  def audit(sheet, action, details = {})
    sheet.events.create!(user: @user, action: action, details: details)
    ActivityLogger.log("timesheet_#{action}", subject: sheet)
  end

  def validate_imports!(sheet)
    imported_ids = sheet.entries.where.not(clock_shift_id: nil).distinct.pluck(:clock_shift_id)
    ClockShift.where(id: imported_ids).each do |shift|
      next unless shift.ended_at
      (sheet.period_start..sheet.period_end).each do |day|
        start_at = [shift.started_at, day.in_time_zone].max
        end_at = [shift.ended_at, (day + 1).in_time_zone].min
        next unless end_at > start_at && ((end_at - start_at) / 3600.0).round(2).positive?
        unless sheet.entries.exists?(clock_shift_id: shift.id, worked_on: day)
          raise Error, 'Clock dates have changed. Re-import your shifts before submitting.'
        end
      end
    end
    sheet.entries.where.not(clock_shift_id: nil).each do |entry|
      shift = ClockShift.find_by(id: entry.clock_shift_id, employee_id: sheet.employee_id)
      if !shift || !shift.ended_at || shift.corrections.where(status: 'pending').exists?
        raise Error, 'Resolve clock corrections and re-import your shifts before submitting.'
      end
      start_at = [shift.started_at, entry.worked_on.in_time_zone].max
      end_at = [shift.ended_at, (entry.worked_on + 1).in_time_zone].min
      expected = [((end_at - start_at) / 3600.0).round(2), 0].max
      raise Error, 'Clock times have changed. Re-import your shifts before submitting.' unless expected == entry.hours
    end
  end

  def import_shifts(sheet)
    from = sheet.period_start.in_time_zone
    to = (sheet.period_end + 1).in_time_zone
    shifts = ClockShift.where(employee_id: sheet.employee_id).where.not(ended_at: nil)
      .where('started_at < ? AND ended_at > ?', to, from).order(:started_at)
    shifts = shifts.to_a
    if shifts.any? { |shift| shift.corrections.where(status: 'pending').exists? }
      raise Error, 'Review pending clock corrections before importing these shifts.'
    end
    sheet.entries.where.not(clock_shift_id: nil).destroy_all
    shifts.each do |shift|
      if shift.corrections.where(status: 'pending').exists?
        raise Error, 'Review pending clock corrections before importing these shifts.'
      end
      (sheet.period_start..sheet.period_end).each do |day|
        start_at = [shift.started_at, day.in_time_zone].max
        end_at = [shift.ended_at, (day + 1).in_time_zone].min
        next unless end_at > start_at
        hours = ((end_at - start_at) / 3600.0).round(2)
        next if hours.zero?
        entry = sheet.entries.find_or_initialize_by(clock_shift_id: shift.id, worked_on: day)
        # Re-import refreshes a corrected shift without creating a duplicate.
        entry.update!(hours: hours, work_type: 'regular', notes: 'Imported from time clock')
      end
    end
  end
end
