# frozen_string_literal: true

module Uploads
  module Importers
    # SwipeSimple Web's native Transactions or Invoices CSV (SwipesimpleReportImporter),
    # kept as reconciliation evidence rows. It does not create sales.
    class SwipesimpleReport < Base
      importer 'swipesimple_report', label: 'SwipeSimple web report (transactions / invoices)', source: 'SwipeSimple', permission: 'sync.write',
        formats: %w[csv], errors: [ArgumentError]

      def self.destination_label = 'SwipeSimple reports'

      def self.params_spec(_document = nil, detection = nil)
        [
          { name: 'kind', label: 'Report', type: :select, required: true, options: [%w[Transactions transactions], %w[Invoices invoices]],
            hint: detection ? nil : 'Which SwipeSimple report this is.' },
          { name: 'merchant_account', label: 'Merchant account (exactly as SwipeSimple shows it)', type: :text, required: true, maxlength: 200 },
          { name: 'currency', label: 'Currency', type: :text, required: true, maxlength: 3, hint: 'Only USD exports are supported.' },
          { name: 'source_timezone', label: 'Time zone the export uses', type: :text, required: true, hint: 'For example America/New_York.' },
          { name: 'exported_at', label: 'When it was exported', type: :text, required: true,
            hint: 'With seconds and a UTC offset, for example 2026-10-20T14:30:00-04:00. This is the export time, not the upload time.' },
          { name: 'invoice_scope', label: 'Invoices: this is a full, unfiltered export', type: :select, required: false, options: [['', ''], %w[Yes full]] }
        ]
      end

      def suggested_params(document, _detection)
        { 'kind' => (document.header.include?('invoice number') ? 'invoices' : 'transactions'), 'currency' => 'USD' }
      end

      def detect(document)
        headers = document.rows(40)[document.header_index].to_a.map { |cell| cell.to_s.strip }
        transactions = (::SwipesimpleReportImporter::TRANSACTION_HEADERS - headers).empty?
        invoices = (::SwipesimpleReportImporter::INVOICE_HEADERS - headers).empty?
        return nil unless transactions || invoices

        detection('swipesimple_report', "SwipeSimple web #{transactions ? 'transactions' : 'invoices'} report", 0.97,
          "Every native column of the SwipeSimple #{transactions ? 'Transactions' : 'Invoices'} export is present (#{headers.first(5).join(', ')}…).")
      end

      def dry_run(document, params, _upload)
        prepared = ::SwipesimpleReportImporter.preview(text!(document), params)
        summary = prepared.summary
        counts = { 'Rows' => summary[:rows], 'Currency' => summary[:currency].to_s }
        counts['Approved sales'] = format('%.2f', summary[:approved_sale_cents] / 100.0)
        counts['Approved refunds'] = format('%.2f', summary[:approved_refund_cents] / 100.0)
        counts['Rows missing a tip'] = summary[:missing_tip_rows]
        outcome('This is saved as reconciliation evidence. It does not create sales.', counts: counts)
      end

      def import!(document, params, _upload, actor:)
        text = text!(document)
        expected = ::SwipesimpleReportImporter.preview(text, params).fingerprint
        ::SwipesimpleReportImporter.import!(text, params, expected_fingerprint: expected, actor: actor)
        outcome('Report saved as reconciliation evidence.', path: helpers.swipesimple_reports_path)
      end
    end
  end
end
