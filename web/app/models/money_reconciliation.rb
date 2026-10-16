# frozen_string_literal: true

class MoneyReconciliation < ApplicationRecord
  include TenantScoped
  encrypts :payload_json

  validates :period_kind, inclusion: { in: %w[daily weekly monthly] }
  validates :period_from, :period_to, :generated_at, :payload_json, presence: true

  def payload
    JSON.parse(payload_json)
  end
end
