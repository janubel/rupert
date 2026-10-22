# frozen_string_literal: true

module Uploads
  module Importers
    # The documented SwipeSimple line-item sales CSV (SwipesimpleImporter): creates
    # completed sales orders in Rupert. It never changes stock or contacts SwipeSimple.
    class SwipesimpleSales < Base
      importer 'swipesimple_sales', label: 'SwipeSimple sales line items', source: 'SwipeSimple', permission: 'sync.write', formats: %w[csv],
        errors: [ArgumentError]

      def self.destination_label = 'Sales'

      def detect(document)
        aliases = ::SwipesimpleImporter::COLUMN_ALIASES.transform_values { |names| names.map { |name| name.gsub(/[^a-z0-9]/, '') } }
        matched = ::SwipesimpleImporter::REQUIRED_COLUMNS.select { |field| document.header_keys.any? { |key| aliases.fetch(field).include?(key) } }
        return nil if matched.size < 7

        all = matched.size == ::SwipesimpleImporter::REQUIRED_COLUMNS.size
        detection('swipesimple_sales', 'SwipeSimple sales line items', all ? 0.9 : 0.5,
          "#{matched.size} of #{::SwipesimpleImporter::REQUIRED_COLUMNS.size} required line-item columns found (order, date, item, quantity, price, payment, status, currency).")
      end

      def dry_run(document, _params, _upload)
        preview = ::SwipesimpleImporter.preview(text!(document))
        summary = preview.summary
        outcome("Would create #{summary[:orders]} sales order#{'s' unless summary[:orders] == 1}. Orders already in Rupert are checked and left alone.",
          counts: { 'Orders' => summary[:orders], 'Lines' => summary[:lines], 'Blank rows skipped' => summary[:skipped_rows],
                    'Gross' => format('%.2f %s', summary[:gross_cents] / 100.0, summary[:currency]) },
          warnings: summary[:warnings])
      end

      def import!(document, _params, _upload, actor:)
        text = text!(document)
        expected = ::SwipesimpleImporter.preview(text).fingerprint
        result = ::SwipesimpleImporter.import!(text, expected_fingerprint: expected)
        outcome('Sales imported. Stock was not changed.',
          counts: { 'Orders created' => result.orders, 'Lines' => result.lines, 'Already present' => result.unchanged_orders }, path: helpers.sales_path)
      end
    end
  end
end
