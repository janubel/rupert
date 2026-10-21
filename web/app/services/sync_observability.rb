# frozen_string_literal: true

class SyncObservability
  # A telemetry storage failure must never change a connector's return value,
  # exception, credential version or transaction boundary.
  def self.store
    ActiveRecord::Base.transaction(requires_new: true) { yield }
  rescue ActiveRecord::ActiveRecordError
    Rails.logger.warn('Sync diagnostics metadata could not be recorded.')
    nil
  end

  def self.observe(source, operation)
    job_id = Current.metadata[:sync_job_id]
    attempt = store do
      queued = SyncAttempt.where(source: source, operation: operation, active_job_id: job_id, status: 'queued').order(id: :desc).first if job_id
      queued ||= SyncAttempt.new(source: source, operation: operation, active_job_id: job_id, queued_at: Time.current)
      queued.update!(status: 'running', started_at: Time.current)
      queued
    end
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    begin
      result = yield
    rescue StandardError => error
      store { attempt&.update!(status: 'failed', error_category: SyncFailure.category(error), finished_at: Time.current) }
      log_run(source, operation, 'failed', started, tenant_id: attempt&.tenant_id, category: SyncFailure.category(error), error: error)
      raise
    else
      busy = result.is_a?(Hash) && result[:busy]
      store { attempt&.update!(status: busy ? 'skipped' : 'succeeded', finished_at: Time.current) }
      log_run(source, operation, busy ? 'skipped' : 'succeeded', started, tenant_id: attempt&.tenant_id)
      result
    end
  end

  # One structured event per sync run (the SyncAttempt row stays the durable record).
  def self.log_run(source, operation, outcome, started, tenant_id:, category: nil, error: nil)
    OpsLog.event('sync', level: outcome == 'failed' ? :error : :info, source: source, operation: operation, outcome: outcome,
      duration_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round, tenant_id: tenant_id,
      job_id: Current.metadata[:sync_job_id], category: category, **OpsLog.error_fields(error))
  end

  def self.queued(job)
    store do
      contexts(job).each do |context|
        SyncAttempt.unscoped.create!(**context, active_job_id: job.job_id,
          status: 'queued', queued_at: Time.current)
      end
    end
  end

  def self.perform(job)
    Current.set(metadata: Current.metadata.merge(sync_job_id: job.job_id)) { yield }
  rescue StandardError
    finish_unstarted(job, 'failed', 'worker')
    raise
  ensure
    finish_unstarted(job, 'skipped', nil)
  end

  def self.finish_unstarted(job, status, category)
    store do
      SyncAttempt.unscoped.where(active_job_id: job.job_id, status: 'queued').update_all(
        status: status, error_category: category, finished_at: Time.current)
    end
  end

  def self.contexts(job)
    name = job.class.name
    args = job.arguments
    options = args.last.is_a?(Hash) ? args.last.symbolize_keys : {}
    if name == 'SyncJob'
      payload = args.first.to_h.symbolize_keys
      tenant_id = payload[:tenant_id]
      return [] unless tenant_id && Tenant.exists?(id: tenant_id, status: 'active')

      sources = payload[:source].present? ? [payload[:source]] : %w[shopify square]
      return sources.filter_map { |source| { tenant_id: tenant_id, source: source, operation: 'catalog' } if %w[shopify square].include?(source) }
    end
    return [{ tenant_id: nil, source: 'google_backup', operation: 'backup' }] if name == 'BackupJob'
    if %w[SquareTimecardSyncJob CtraxLaborSyncJob].include?(name)
      tenant_id = args.first
      source = name == 'CtraxLaborSyncJob' ? 'ctrax' : 'square'
      return Tenant.exists?(id: tenant_id, status: 'active') ? [{ tenant_id: tenant_id, source: source, operation: 'timecards' }] : []
    end

    source, operation, provider = {
      'CtraxStockSyncJob' => %w[ctrax stock ctrax], 'CtraxSalesSyncJob' => %w[ctrax sales ctrax],
      'SwipesimpleWebSyncJob' => %w[swipesimple web swipesimple],
      'IrisDailyDepositsWebJob' => %w[bank web iris_reporting],
      'IrisReportingJob' => %w[bank reporting iris_reporting],
      'AuthorizeNetReportingJob' => %w[authorize_net reporting authorize_net_reporting]
    }[name]
    return [] unless provider

    id = options[:connection_id] || (args.first unless args.first.is_a?(Hash))
    connection = PosConnection.unscoped.find_by(id: id, provider: provider) if id
    return [] unless connection && connection.tenant&.status == 'active'
    return [] if options[:tenant_id] && options[:tenant_id] != connection.tenant_id

    [{ tenant_id: connection.tenant_id, source: source, operation: operation }]
  end
end
