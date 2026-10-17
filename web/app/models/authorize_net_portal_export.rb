# frozen_string_literal: true

# Dated merchant-portal evidence, separate from authenticated API reconciliation.
class AuthorizeNetPortalExport < ApplicationRecord
  include TenantScoped
  encrypts :original_csv
  encrypts :records_json
  has_many :observations, class_name: 'AuthorizeNetPortalObservation', dependent: :delete_all

  validates :gateway_id, :fingerprint, :exported_at, presence: true
  validates :kind, inclusion: { in: %w[settled unsettled] }
  after_save -> { AuthorizeNetPortalObservation.record!(self) }, if: -> { saved_change_to_records_json? || saved_change_to_exported_at? || saved_change_to_gateway_id? }

  def records
    JSON.parse(records_json)
  end

  # Whole-history view; day and period readers use AuthorizeNetPortalObservation.
  def self.latest_records
    AuthorizeNetPortalObservation.latest_all
  end
end
