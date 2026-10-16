# frozen_string_literal: true

class DirectorySyncJob < ApplicationJob
  queue_as :default

  def perform(tenant_id = nil, provider = nil, kind = nil, manual: false)
    unless tenant_id
      Tenant.where(status: 'active').find_each do |tenant|
        Current.set(tenant: tenant) do
          EnvStore.clear_cache!
          Directories::Sync::PAIRS.each do |source, kinds|
            next unless Directories::Sync.available?(source)
            next if source == 'ctrax' && !PosConnection.find_by(provider: source)&.hourly_sync_enabled
            next if source == 'swipesimple' && !PosConnection.find_by(provider: source)&.reporting_enabled

            kinds.each { |directory| self.class.perform_later(tenant.id, source, directory) }
          end
        end
      end
      return
    end
    tenant = Tenant.find_by(id: tenant_id, status: 'active')
    return unless tenant

    Current.set(tenant: tenant) do
      EnvStore.clear_cache!
      return unless Directories::Sync.available?(provider)
      return if provider == 'ctrax' && !manual && !PosConnection.find_by(provider: provider)&.hourly_sync_enabled
      return if provider == 'swipesimple' && !manual && !PosConnection.find_by(provider: provider)&.reporting_enabled

      Directories::Sync.call(provider: provider, kind: kind)
    end
  rescue Directories::Sync::Error, Directories::Sync::Busy
    # The safe error and retained last-success count are visible in the directory.
    nil
  end
end
