# frozen_string_literal: true

# Checks fulfillment exceptions for each active tenant. It posts only when the
# exception set changes, keeping the Announcements channel low-noise.
class FulfillmentMonitorJob < ApplicationJob
  queue_as :default

  retry_on StandardError, wait: :polynomially_longer, attempts: 5

  def perform
    Tenant.where(status: 'active').find_each do |tenant|
      Current.tenant = tenant
      begin
        FulfillmentMonitor.check! if TeamChat::Notices.configured?
      ensure
        Current.tenant = nil
      end
    end
  end
end
