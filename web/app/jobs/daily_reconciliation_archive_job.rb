# frozen_string_literal: true

# Revisit a week of days for late-arriving imports. Unchanged reports replay safely.
class DailyReconciliationArchiveJob < ActiveJob::Base
  queue_as :default

  def perform
    Tenant.where(status: 'active').find_each do |tenant|
      Current.set(tenant: tenant) do
        Time.use_zone('America/New_York') do
          (1..7).each { |days_ago| DailyMoneyReconciliation.new(day: (Date.current - days_ago).iso8601).archive! }
        end
      end
    rescue StandardError => e
      logger.error("#{self.class}: archive failed for tenant #{tenant.id}: #{e.class}")
    end
  end
end
