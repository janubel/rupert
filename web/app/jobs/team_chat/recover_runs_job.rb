# frozen_string_literal: true

module TeamChat
  class RecoverRunsJob < ApplicationJob
    queue_as :default

    def perform
      Run.unscoped.where(state: Run::ACTIVE).find_each do |run|
        Current.tenant = Tenant.find_by(id: run.tenant_id)
        if run.deadline_at <= Time.current
          run.expire!
        elsif run.state == 'queued' || run.lease_until.nil? || run.lease_until <= Time.current
          if run.attempts >= Run::MAX_ATTEMPTS
            run.with_lock do
              stale = run.state == 'queued' || (run.state == 'running' && (run.lease_until.nil? || run.lease_until <= Time.current))
              run.terminalize!('failed', 'This reply was interrupted too many times. Please try again.') if stale && run.attempts >= Run::MAX_ATTEMPTS
            end
          elsif Run.unscoped.where(id: run.id, state: Run::ACTIVE).where('dispatched_at IS NULL OR dispatched_at < ?', 1.minute.ago)
                   .update_all(dispatched_at: Time.current) == 1
            ReplyJob.perform_later(run.message_id)
          end
        end
      end
    ensure
      Current.reset
    end
  end
end
