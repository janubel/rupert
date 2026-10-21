# frozen_string_literal: true

class SwipesimpleWebSyncJob < ApplicationJob
  queue_as :default

  def perform(connection_id = nil, manual: false)
    unless connection_id
      PosConnection.unscoped.joins(:tenant).where(provider: 'swipesimple', vendor_approved: true,
        reporting_enabled: true, tenants: { status: 'active' }).find_each do |connection|
        self.class.perform_later(connection.id)
      end
      return
    end
    scope = PosConnection.unscoped.where(id: connection_id, provider: 'swipesimple')
    scope = scope.where(reporting_enabled: true) unless manual
    connection = scope.first
    return unless connection&.tenant&.status == 'active'

    Current.set(tenant: connection.tenant) do
      next unless connection.vendor_approved && connection.credentials_saved?

      begin
        result = SwipesimpleWeb::Sync.call(connection: connection)
        next if result[:busy]

        ActivityLogger.log('swipesimple_web_synced', subject: connection,
          details: "#{manual ? 'manual' : 'scheduled'}: #{result[:transactions]} transactions, #{result[:invoices]} invoices, reports #{result[:reports]}, items #{result[:items]}")
      rescue SwipesimpleWeb::Client::Error => e
        ActivityLogger.log('swipesimple_web_sync_failed', subject: connection, details: e.message)
      end
    end
  end
end
