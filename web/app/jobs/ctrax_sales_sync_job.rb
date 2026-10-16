# frozen_string_literal: true

class CtraxSalesSyncJob < ApplicationJob
  queue_as :default

  def perform(connection_id = nil, date: nil, manual: false)
    unless connection_id
      PosConnection.unscoped.joins(:tenant).where(provider: 'ctrax', reporting_enabled: true,
        tenants: { status: 'active' }).find_each { |connection| self.class.perform_later(connection.id) }
      return
    end
    connections = PosConnection.unscoped.where(id: connection_id, provider: 'ctrax', vendor_approved: true)
    connections = connections.where(reporting_enabled: true) unless manual
    connection = connections.first
    return unless connection&.tenant&.status == 'active' && connection.credentials_saved?

    Current.set(tenant: connection.tenant) do
      dates = date ? [Date.iso8601(date)] : [Time.current.in_time_zone('America/New_York').to_date, Time.current.in_time_zone('America/New_York').to_date - 1]
      dates.each do |day|
        result = Ctrax::SalesSync.call(connection: connection.reload, date: day)
        ActivityLogger.log('ctrax_sales_synced', subject: connection,
          details: "#{result[:date]}: #{result[:stores]} stores, #{result[:orders]} orders")
      end
    rescue Ctrax::Client::Error, Date::Error => e
      message = e.is_a?(Ctrax::Client::Error) ? e.message : 'Choose a valid business date.'
      PosConnection.where(id: connection.id, lock_version: connection.lock_version).update_all(last_report_status: 'failed', last_report_message: message)
      ActivityLogger.log('ctrax_sales_sync_failed', subject: connection, details: message)
    end
  end
end
