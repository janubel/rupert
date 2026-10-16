# frozen_string_literal: true

class AuthorizeNetEventJob < ApplicationJob
  queue_as :default
  retry_on AuthorizeNetReporting::Client::Error, wait: :polynomially_longer, attempts: 5

  def perform(tenant_id:, connection_id:, webhook_scope:, transaction_id:)
    tenant = Tenant.find_by(id: tenant_id, status: 'active')
    return unless tenant

    Current.set(tenant: tenant) do
      connection = PosConnection.find_by(id: connection_id, provider: 'authorize_net_reporting',
        vendor_approved: true, reporting_enabled: true)
      return unless connection&.credentials_saved? && connection.webhook_scope == webhook_scope

      AuthorizeNetReporting::Import.call(connection: connection, transaction_id: transaction_id)
    end
  end
end
