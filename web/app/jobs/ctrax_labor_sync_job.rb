# frozen_string_literal: true

class CtraxLaborSyncJob < ApplicationJob
  queue_as :default
  limits_concurrency to: 1, key: ->(tenant_id = nil) { tenant_id || 'scheduler' }, duration: 15.minutes

  def perform(tenant_id = nil)
    unless tenant_id
      Tenant.where(status: 'active').find_each do |tenant|
        Current.set(tenant: tenant) do
          self.class.perform_later(tenant.id) if CtraxLaborSync.enabled?
        end
      end
      return
    end
    tenant = Tenant.find_by(id: tenant_id, status: 'active')
    return unless tenant

    Current.set(tenant: tenant) { CtraxLaborSync.call }
  end
end
