# frozen_string_literal: true

class AuthorizeNetReportingJob < ApplicationJob
  queue_as :default

  def perform(tenant_id: nil, connection_id: nil, setup_version: nil, from: nil, to: nil)
    tenants = Tenant.where(status: 'active')
    tenants = tenants.where(id: tenant_id) if tenant_id
    tenants.find_each do |tenant|
      Current.set(tenant: tenant) do
        connections = PosConnection.where(provider: 'authorize_net_reporting', vendor_approved: true)
        connections = connection_id ? connections.where(id: connection_id) : connections.where(reporting_enabled: true)
        connection = connections.first
        next unless connection&.credentials_saved?
        next if setup_version && connection.lock_version != setup_version
        begin
          arguments = { connection: connection }
          arguments.merge!(from: Time.iso8601(from), to: Time.iso8601(to)) if from && to
          AuthorizeNetReporting::Import.call(**arguments)
        rescue AuthorizeNetReporting::Client::Error => e
          PosConnection.where(id: connection.id, lock_version: connection.lock_version).update_all(
            last_report_status: 'failed', last_report_message: e.message, updated_at: Time.current)
        end
      end
    end
  end
end
