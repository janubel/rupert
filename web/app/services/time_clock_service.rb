# frozen_string_literal: true

class TimeClockService
  class Error < StandardError; end

  def self.worker_for(user)
    workers = People::Employee.where(tenant_id: Current.tenant_id, user_id: user.id, status: 'active').limit(2).to_a
    workers.one? ? workers.first : nil
  end

  def self.clock_in(user:, request_token:)
    worker = worker_for(user)
    raise Error, 'Ask an administrator to link exactly one active worker record to your sign-in account.' unless worker

    ClockShift.serialize_worker(worker.id) do
      worker.reload
      unless worker.active? && worker.user_id == user.id && worker.tenant_id == Current.tenant_id
        raise Error, 'Your worker link changed. Ask an administrator to check your active worker record.'
      end
      existing = ClockShift.find_by(user_id: user.id, request_token: request_token)
      existing ||= ClockShift.open.find_by(user_id: user.id)
      existing || ClockShift.create!(user: user, employee: worker, employee_key: worker.id.to_s,
        employee_name: worker.name, employment_type: worker.employment_type,
        started_at: Time.current, request_token: request_token)
    end
  rescue ActiveRecord::RecordNotUnique
    ClockShift.find_by(user_id: user.id, request_token: request_token) || ClockShift.open.find_by!(user_id: user.id)
  end

  def self.clock_out(user:, shift_id:)
    shift = ClockShift.find_by!(id: shift_id, user_id: user.id)
    shift.serialize_change { shift.update!(ended_at: Time.current) unless shift.ended_at }
    shift
  end

  def self.request_correction(user:, shift_id:, attributes:)
    shift = ClockShift.find_by!(id: shift_id, user_id: user.id)
    correction = nil
    shift.serialize_change do
      correction = shift.corrections.create!(attributes.slice(:proposed_started_at, :proposed_ended_at, :reason).merge(
        requested_by_id: user.id, original_started_at: shift.started_at, original_ended_at: shift.ended_at
      ))
    end
    correction
  end

  def self.review(correction:, reviewer:, approve:)
    raise Error, 'Payroll write permission is required.' unless reviewer.can?('payroll.write')
    raise ActiveRecord::RecordNotFound unless correction.tenant_id == Current.tenant_id &&
      (reviewer.super_admin? || reviewer.tenant_id == Current.tenant_id)

    shift = correction.clock_shift
    shift.serialize_change do
      correction.reload
      if correction.status != 'pending'
        return correction if correction.status == (approve ? 'approved' : 'rejected')

        raise Error, 'This correction has already been reviewed with a different decision.'
      end

      if approve
        unless shift.started_at == correction.original_started_at && shift.ended_at == correction.original_ended_at
          raise Error, 'This shift changed after the request. Reject it and request a fresh correction.'
        end
        shift.update!(started_at: correction.proposed_started_at, ended_at: correction.proposed_ended_at)
      end
      correction.update!(status: approve ? 'approved' : 'rejected', reviewed_by_id: reviewer.id, reviewed_at: Time.current)
    end
    correction
  end
end
