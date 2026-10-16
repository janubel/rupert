# frozen_string_literal: true

class IrisReportingJob < ApplicationJob
  queue_as :default

  def perform(tenant_id: nil, connection_id: nil, setup_version: nil, from: nil, to: nil)
    tenants = Tenant.where(status: 'active')
    tenants = tenants.where(id: tenant_id) if tenant_id
    tenants.find_each do |tenant|
      Current.set(tenant: tenant) do
        connections = PosConnection.where(provider: 'iris_reporting', vendor_approved: true, reporting_auth_mode: 'api_key')
        connections = connection_id ? connections.where(id: connection_id) : connections.where(reporting_enabled: true)
        connection = connections.first
        next unless connection&.credentials_saved?
        next if setup_version && connection.lock_version != setup_version

        begin
          args = { connection: connection }
          args.merge!(from: Date.iso8601(from), to: Date.iso8601(to)) if from && to
          IrisReporting::Import.call(**args)
        rescue IrisReporting::Client::Error => e
          PosConnection.where(id: connection.id, lock_version: connection.lock_version).update_all(
            last_report_status: 'failed', last_report_message: e.message, updated_at: Time.current)
        end
      end
    end
  end
end
