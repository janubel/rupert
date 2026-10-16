# frozen_string_literal: true

class SyncQueueHealth
  def self.worker
    return { state: 'Unknown · queue adapter is not Solid Queue', last_at: nil } unless ActiveJob::Base.queue_adapter.is_a?(ActiveJob::QueueAdapters::SolidQueueAdapter)

    time = SolidQueue::Process.where(kind: 'Worker').maximum(:last_heartbeat_at)
    { state: time && time > 2.minutes.ago ? 'Recent worker heartbeat' : 'No recent worker heartbeat', last_at: time }
  rescue ActiveRecord::ActiveRecordError
    { state: 'Unknown · queue database unavailable', last_at: nil }
  end

  # Only a tenant-scoped attempt's job ID is looked up. Arguments and raw
  # FailedExecution error payloads are deliberately never read or returned.
  def self.execution(attempt)
    return { state: 'No job receipt', retry_at: nil } unless attempt&.active_job_id

    job = SolidQueue::Job.find_by(active_job_id: attempt.active_job_id)
    return { state: 'No retained queue receipt', retry_at: nil } unless job
    return { state: 'Failed in worker', retry_at: nil } if job.failed_execution
    return { state: 'Scheduled', retry_at: job.scheduled_execution.scheduled_at } if job.scheduled_execution
    return { state: 'Waiting for concurrency slot', retry_at: nil } if job.blocked_execution
    return { state: 'Running in worker', retry_at: nil } if job.claimed_execution
    return { state: 'Ready for worker', retry_at: nil } if job.ready_execution

    { state: 'Finished or released', retry_at: nil }
  rescue ActiveRecord::ActiveRecordError
    { state: 'Unknown · queue database unavailable', retry_at: nil }
  end
end
