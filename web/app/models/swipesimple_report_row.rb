# frozen_string_literal: true

class SwipesimpleReportRow < ApplicationRecord
  include TenantScoped

  belongs_to :swipesimple_export
  encrypts :reference_number
  encrypts :source_number

  # Every export remains immutable evidence. Transactions use their latest
  # identity observation; invoices use the latest complete account snapshot.
  # Invoice numbers are non-unique. Import time never orders source snapshots.
  def self.latest
    joins(:swipesimple_export).where(<<~SQL.squish)
      (swipesimple_exports.kind = 'transactions' AND NOT EXISTS (
        SELECT 1 FROM swipesimple_report_rows newer_row
        JOIN swipesimple_exports newer_export ON newer_export.id = newer_row.swipesimple_export_id
        WHERE newer_row.tenant_id = swipesimple_report_rows.tenant_id
          AND newer_row.identity = swipesimple_report_rows.identity
          AND (newer_export.exported_at > swipesimple_exports.exported_at
            OR (newer_export.exported_at = swipesimple_exports.exported_at
              AND newer_export.id > swipesimple_exports.id))
      )) OR (swipesimple_exports.kind = 'invoices' AND NOT EXISTS (
        SELECT 1 FROM swipesimple_exports newer_export
        WHERE newer_export.tenant_id = swipesimple_exports.tenant_id
          AND newer_export.kind = 'invoices'
          AND newer_export.merchant_account = swipesimple_exports.merchant_account
          AND newer_export.currency = swipesimple_exports.currency
          AND (newer_export.exported_at > swipesimple_exports.exported_at
            OR (newer_export.exported_at = swipesimple_exports.exported_at
              AND newer_export.id > swipesimple_exports.id))
      ))
    SQL
  end
end
