# frozen_string_literal: true

module SwipesimpleWeb
  # Stores checked SwipeSimple report months. Each month atomically replaces
  # the stored days in its range and records the covered range with the raw
  # CSV. Months that have ended (in the store's timezone) are also retained as
  # reconciliation evidence; the still-changing current month is kept only on
  # its pull record, so half-hourly pulls do not pile up documents.
  class ReportStore
    MODELS = { 'tax' => 'SwipesimpleTaxDay', 'sales' => 'SwipesimpleSalesDay' }.freeze
    TIMEZONE = 'America/New_York'

    def self.today = Time.current.in_time_zone(TIMEZONE).to_date

    def self.replace!(chunk, merchant_account:)
      model = MODELS.fetch(chunk.topic).constantize
      now = Time.current
      ActiveRecord::Base.transaction(requires_new: true) do
        document = if chunk.to < today
          ReconciliationEvidence.retain!(bytes: chunk.text, filename: "swipesimple-#{chunk.topic}-report-#{chunk.from}-#{chunk.to}.csv",
            source: 'swipesimple', kind: 'processor_report', from: chunk.from.iso8601, to: chunk.to.iso8601,
            metadata: { 'merchant' => merchant_account, 'report_kind' => "swipesimple_#{chunk.topic}", 'currency' => 'USD',
                        'source_digest' => chunk.sha256, 'coverage' => 'swipesimple_reports_csv' })
        end
        model.where(merchant_account: merchant_account, business_date: chunk.from..chunk.to).delete_all
        chunk.rows.each { |row| model.create!(row.merge(merchant_account: merchant_account, source_digest: chunk.sha256, pulled_at: now)) }
        SwipesimpleReportPull.where(merchant_account: merchant_account, topic: chunk.topic)
          .where('period_from >= ? AND period_to <= ?', chunk.from, chunk.to).delete_all
        SwipesimpleReportPull.create!(merchant_account: merchant_account, topic: chunk.topic, period_from: chunk.from, period_to: chunk.to,
          row_count: chunk.rows.size, source_digest: chunk.sha256, original_csv: chunk.text, reconciliation_document_id: document&.id, pulled_at: now)
      end
    end

    # Replaces the account's item snapshot only when the workbook bytes changed.
    def self.replace_items!(items, merchant_account:)
      snapshot = SwipesimpleItemSnapshot.find_or_initialize_by(merchant_account: merchant_account)
      return false if snapshot.persisted? && snapshot.sha256 == items.sha256

      snapshot.update!(records_json: items.records, row_count: items.records.size, sha256: items.sha256,
        source_filename: SwipesimpleItemSnapshot::AUTOMATIC_SOURCE, captured_at: Time.current, imported_by: nil)
      true
    end

    # The merchant accounts verified by earlier transaction pulls.
    def self.verified_accounts
      accounts = SwipesimpleExport.where(kind: 'transactions').distinct.order(:merchant_account).pluck(:merchant_account)
      raise Client::Error, :identity if accounts.empty?

      accounts
    end
  end
end
