# frozen_string_literal: true

class MoneyReconciliationJob < ApplicationJob
  queue_as :default

  def perform(kind)
    Tenant.where(status: 'active').find_each do |tenant|
      Current.set(user: nil, tenant: tenant) do
        MoneyReconciliationReport.new(kind: kind, date: MoneyReconciliationReport.previous_period(kind)).save!
      rescue MoneyReconciliationReport::Locked => e
        # The locked review stays as it was; other workspaces still run.
        Rails.logger.info("MoneyReconciliationJob skipped #{kind} for #{tenant.id}: #{e.message}")
      end
    end
  end
end
