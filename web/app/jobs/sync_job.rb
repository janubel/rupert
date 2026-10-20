# frozen_string_literal: true

class SyncJob < ApplicationJob
  queue_as :default

  # Raised (wrapping the original) when a sync failed for a reason that
  # usually clears on its own: network, timeout, vendor 5xx, rate limit.
  # Each retry starts a fresh SyncRun; the mirror is idempotent and the
  # previous run was already marked failed, so the per-tenant lock is free.
  class TransientFailure < StandardError; end

  TRANSIENT_CATEGORIES = %w[network timeout rate_limit vendor storage].freeze

  retry_on ActiveRecord::PreparedStatementCacheExpired, wait: 5.seconds, attempts: 2
  retry_on TransientFailure, wait: :polynomially_longer, attempts: 4 do |job, error|
    BuzzNotifyJob.perform_later("Sync failed after #{job.executions} attempts: #{error.message.to_s[0, 300]}")
    raise error # keep the failed execution visible in the queue (System page / readiness)
  end

  def perform(payload = {})
    mode = payload['mode'] || payload[:mode] || 'manual'
    source = payload['source'] || payload[:source]
    actor = payload['actor'] || payload[:actor] || 'scheduler'
    tenant_id = payload['tenant_id'] || payload[:tenant_id]

    tenant = Tenant.find(tenant_id) if tenant_id
    raise ArgumentError, 'No tenant_id provided' if tenant.nil?

    Current.tenant = tenant

    run = if source.present?
      SyncEngine.run_source!(source, actor: actor, tenant: tenant)
    else
      SyncEngine.run!(mode: mode, actor: actor, tenant: tenant)
          end

    BuzzNotifyJob.perform_later(sync_message(run))
    SalesAnnouncementJob.perform_later(tenant_id)
  rescue TransientFailure
    raise
  rescue StandardError => e
    if TRANSIENT_CATEGORIES.include?(SyncFailure.category(e)) || HttpRetry::NETWORK_ERRORS.any? { |type| e.is_a?(type) }
      raise TransientFailure, "#{e.class}: #{e.message.to_s[0, 300]}"
    end

    BuzzNotifyJob.perform_later("Sync failed: #{e.message.to_s[0, 300]}")
    raise
  ensure
    Current.tenant = nil
  end

  private

  def sync_message(run)
    drift = nil
    if run.details.present?
      details = if run.details.is_a?(String)
        begin
          JSON.parse(run.details)
        rescue StandardError
          nil
        end
      else
        run.details
                end
      drift = details&.dig('reconcile', 'drift_count')
    end
    status = run.success? ? 'Sync complete' : "Sync #{run.status}"
    "#{status} · #{run.source || 'all sources'} · #{run.mode} · drift #{drift.nil? ? 'n/a' : drift}"
  end
end
