# frozen_string_literal: true

class CtraxStockSyncJob < ApplicationJob
  queue_as :default

  def perform(connection_id = nil, manual: false)
    unless connection_id
      PosConnection.unscoped.joins(:tenant).where(provider: 'ctrax', hourly_sync_enabled: true,
        tenants: { status: 'active' }).find_each do |connection|
        self.class.perform_later(connection.id)
      end
      return
    end
    connections = PosConnection.unscoped.where(id: connection_id, provider: 'ctrax')
    connections = connections.where(hourly_sync_enabled: true) unless manual
    connection = connections.first
    return unless connection&.tenant&.status == 'active'

    Current.set(tenant: connection.tenant) do
      next unless connection.vendor_approved && connection.credentials_saved?

      begin
        result = Ctrax::StockSync.call(connection: connection)
        ActivityLogger.log('ctrax_stock_synced', subject: connection,
          details: "#{manual ? 'manual' : 'scheduled'}: #{result[:stores]} stores, #{result[:variants]} variants")
      rescue Ctrax::Client::Error => e
        ActivityLogger.log('ctrax_stock_sync_failed', subject: connection, details: e.message)
      end
    end
  end
end
