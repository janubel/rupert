# frozen_string_literal: true

class IrisDailyDepositsWebJob < ApplicationJob
  queue_as :default

  def perform(connection_id = nil, manual: false, setup_version: nil)
    unless connection_id
      PosConnection.unscoped.joins(:tenant).where(provider: 'iris_reporting', reporting_auth_mode: 'web', vendor_approved: true,
        reporting_enabled: true, tenants: { status: 'active' }).find_each { |connection| self.class.perform_later(connection.id) }
      return
    end
    scope = PosConnection.unscoped.where(id: connection_id, provider: 'iris_reporting', reporting_auth_mode: 'web')
    scope = scope.where(reporting_enabled: true) unless manual
    connection = scope.first
    return unless connection&.tenant&.status == 'active' && connection.vendor_approved && connection.credentials_saved?
    return if setup_version && connection.lock_version != setup_version

    Current.set(tenant: connection.tenant) do
      result = IrisReporting::WebSync.call(connection: connection)
      ActivityLogger.log('iris_daily_deposits_web_synced', subject: connection, details: "#{manual ? 'manual' : 'scheduled'}: native deposits verified") unless result[:busy]
    rescue IrisReporting::WebClient::Error => e
      ActivityLogger.log('iris_daily_deposits_web_failed', subject: connection, details: e.message)
    end
  end
end
