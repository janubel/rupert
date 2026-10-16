# frozen_string_literal: true

# Dated merchant-portal evidence, separate from authenticated API reconciliation.
class AuthorizeNetPortalExport < ApplicationRecord
  include TenantScoped
  encrypts :original_csv
  encrypts :records_json

  validates :gateway_id, :fingerprint, :exported_at, presence: true
  validates :kind, inclusion: { in: %w[settled unsettled] }

  def records
    JSON.parse(records_json)
  end

  def self.latest_records
    observations = {}
    select(:id, :gateway_id, :records_json, :exported_at).find_each do |receipt|
      receipt.records.each do |row|
        key = [receipt.gateway_id, row.fetch('transaction_id')]
        previous = observations[key]
        next if previous && previous.fetch('exported_at') > receipt.exported_at.iso8601(6)

        observations[key] = row.merge('gateway_id' => receipt.gateway_id,
          'export_id' => receipt.id, 'exported_at' => receipt.exported_at.iso8601(6))
      end
    end
    observations.values
  end
end
