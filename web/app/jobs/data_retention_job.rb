# frozen_string_literal: true

# Nightly retention pruning, per tenant (TenantScoped models need a tenant in
# context). One tenant failing must not stop the others.
class DataRetentionJob < ActiveJob::Base
  queue_as :default

  def perform
    Tenant.find_each do |tenant|
      Current.tenant = tenant
      DataRetention.prune_all!
    rescue StandardError => e
      logger.error("#{self.class}: retention prune failed for tenant #{tenant.id}: #{e.class}: #{e.message}")
    ensure
      Current.tenant = nil
    end
    Current.set(tenant: nil) do
      DataRetention.prune(SyncAttempt.where(source: 'google_backup'), column: 'queued_at', older_than: 90.days.ago)
      DataRetention.prune(WebhookDelivery.all, column: 'received_at', older_than: WebhookDelivery::RETENTION.ago)
    end
  end
end
