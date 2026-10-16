# frozen_string_literal: true

# Serialize decisions and balance changes together. Repeated review/cancel
# requests cannot consume or restore the same allowance twice.
class LeaveRequestWorkflow
  def self.change(request, event, self_service: false)
    People::LeaveRequest.transaction do
      Tenant.where(id: Current.tenant_id).update_all('updated_at = updated_at')
      request.reload
      raise ActiveRecord::RecordNotFound unless request.tenant_id == Current.tenant_id
      if self_service
        worker = TimeClockService.worker_for(Current.user, include_on_leave: true)
        raise Pundit::NotAuthorizedError unless event == :cancel && worker && request.employee_id == worker.id
        return false unless request.requested?
      else
        raise Pundit::NotAuthorizedError unless Current.user&.active? && Current.user.can?('leave.write')
      end
      return false unless request.public_send("may_#{event}?")

      approved_before = request.approved?
      request.public_send("#{event}!")
      if event.in?(%i[approve deny])
        request.update!(reviewed_by: Current.user.id, reviewed_at: Time.current)
      end
      if request.leave_type != 'unpaid' && (event == :approve || (event == :cancel && approved_before))
        balance = request.employee.leave_balances.find_or_initialize_by(leave_type: request.leave_type, year: request.starts_on.year)
        hours = request.hours.presence || request.days * 8
        balance.used_hours = event == :approve ? balance.used_hours + hours : [balance.used_hours - hours, 0].max
        balance.save!
      end
      ActivityLogger.log("leave_#{event == :approve ? 'approved' : event == :deny ? 'denied' : 'cancelled'}", subject: request)
      true
    end
  end
end
