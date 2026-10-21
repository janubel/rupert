# frozen_string_literal: true

module Uploads
  module Importers
    # Sniffs files Rupert can name but cannot import yet. It never routes: a file it
    # recognizes stays in the inbox as "needs review" with the reason, and gets
    # re-sniffed (Re-run recognition) when a real importer for the type ships.
    class Recognized < Base
      importer 'recognized', label: 'Recognized, no importer', source: 'Various', permission: 'uploads.write', formats: %w[csv text json pdf xlsx]

      def detect(document)
        [square(document), rupert_timesheets(document), ctrax(document), quickbooks_excel(document)].compact
      end

      private

      def square(document)
        return nil unless %w[csv xlsx].include?(document.format)

        keys = document.header_keys
        if keys.include?('grosssales') && keys.include?('netsales')
          unmatched(document, 'square:sales', 'Square sales / item sales export', 'Square', 0.85,
            'The columns include Gross Sales and Net Sales, which Square item and transaction exports use.')
        elsif keys.include?('token') && keys.include?('itemname') && keys.include?('variationname')
          unmatched(document, 'square:catalog', 'Square item library export', 'Square', 0.85,
            'The columns include Token, Item Name and Variation Name, the Square item library layout.')
        end
      end

      def rupert_timesheets(document)
        keys = document.header_keys
        return nil unless document.format == 'csv' && keys.include?('recordkind') && keys.include?('periodstart') && keys.include?('compensationtotalcents')

        unmatched(document, 'rupert:timesheets', 'Rupert timesheet export', 'Rupert', 0.95,
          'These are Rupert’s own timesheet export columns. It is a file Rupert produced, so there is nothing to import; keep it as a record.')
      end

      def ctrax(document)
        return nil unless document.filename.match?(/c[-_ ]?trax/i)

        unmatched(document, 'ctrax:file', 'File named for C-Trax', 'C-Trax', 0.3,
          'Only the file name mentions C-Trax. Rupert reads C-Trax through its connection, not from uploads, so there is no importer for this file.')
      end

      def quickbooks_excel(document)
        return nil unless document.format == 'xlsx'

        kind, confidence, reason = Quickbooks.classify(document)
        return nil unless kind

        unmatched(document, "quickbooks:#{kind}", "QuickBooks — #{Quickbooks::KINDS.fetch(kind)} (Excel)", 'QuickBooks', [confidence, 0.9].min,
          "#{reason} It is an Excel file, and the QuickBooks importer reads CSV. Open it in Excel and Save As CSV, then upload that.")
      end

      # importer: nil means "named, not routable".
      def unmatched(_document, type, label, source, confidence, reason)
        Detection.new(type: type, label: label, confidence: confidence, reason: reason, importer: nil, source: source)
      end
    end
  end
end
