# frozen_string_literal: true

class SyncJob < ApplicationJob
  queue_as :default

  retry_on ActiveRecord::PreparedStatementCacheExpired, wait: 5.seconds, attempts: 2

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
  rescue StandardError => e
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
