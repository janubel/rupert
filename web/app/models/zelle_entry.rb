# frozen_string_literal: true

# A Zelle credit or debit as listed on a bank statement. It is payment
# evidence only (tender "zelle", verification "unverified" until a person
# reconciles it); it never creates a Core::Order, ledger entry or SwipeSimple
# total.
class ZelleEntry < ApplicationRecord
  include TenantScoped

  TENDER = 'zelle'
  DIRECTIONS = %w[credit debit].freeze

  belongs_to :zelle_export
  encrypts :bank_reference
  encrypts :counterparty
  encrypts :memo
  validates :direction, inclusion: { in: DIRECTIONS }
  validates :tender, inclusion: { in: [TENDER] }

  # Overlapping exports re-list the same bank transactions. Each identity
  # counts once, from the export taken latest (ties: the later import).
  def self.latest
    joins(:zelle_export).where(<<~SQL.squish)
      NOT EXISTS (
        SELECT 1 FROM zelle_entries newer_entry
        JOIN zelle_exports newer_export ON newer_export.id = newer_entry.zelle_export_id
        WHERE newer_entry.tenant_id = zelle_entries.tenant_id
          AND newer_entry.identity = zelle_entries.identity
          AND (newer_export.exported_at > zelle_exports.exported_at
            OR (newer_export.exported_at = zelle_exports.exported_at AND newer_export.id > zelle_exports.id))
      )
    SQL
  end
end
