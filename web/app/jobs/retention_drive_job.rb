# frozen_string_literal: true

class RetentionDriveJob < ApplicationJob
  queue_as :default

  def perform(tenant_id = nil)
    unless tenant_id
      Tenant.where(status: 'active').find_each { |tenant| self.class.perform_later(tenant.id) }
      return
    end
    tenant = Tenant.find_by(id: tenant_id, status: 'active')
    return unless tenant

    Current.set(tenant: tenant) do
      connection = RetentionDriveConnection.first
      RetentionDrive.new(connection).sync! if connection&.connected? && connection.enabled
    end
  rescue StandardError => e
    logger.error("#{self.class}: retention sync failed: #{e.class}")
  end
end
