# frozen_string_literal: true

module Uploads
  module Importers
    # The Authorize.net merchant-portal "Expanded Fields / Comma Separated" export
    # (AuthorizeNetPortalImporter), kept as a portal snapshot. Not an API read.
    class AuthorizeNetPortal < Base
      importer 'authorize_net_portal', label: 'Authorize.net portal export', source: 'Authorize.net', permission: 'sync.write', formats: %w[csv],
        errors: [ArgumentError]

      def self.destination_label = 'Authorize.net portal exports'

      def self.params_spec(_document = nil, _detection = nil)
        [
          { name: 'gateway_id', label: 'Gateway ID', type: :text, required: true, hint: 'The numeric Gateway ID shown in the merchant portal.' },
          { name: 'kind', label: 'Transactions in this file', type: :select, required: true, options: [%w[Settled settled], %w[Unsettled unsettled]] },
          { name: 'exported_at', label: 'When it was exported', type: :text, required: true,
            hint: 'With a UTC offset, for example 2026-10-20T14:30:00-04:00. This is the export time, not the upload time.' }
        ]
      end

      def detect(document)
        headers = document.rows(40)[document.header_index].to_a.map { |cell| cell.to_s.strip }
        missing = ::AuthorizeNetPortalImporter::REQUIRED - headers
        return nil if missing.size > 3

        detection('authorize_net_portal', 'Authorize.net portal export', missing.empty? ? 0.97 : 0.6,
          missing.empty? ? 'All the native Expanded Fields columns (Transaction ID, Settlement Amount, Submit Date/Time…) are present.' : "Most Authorize.net portal columns are present; missing #{missing.to_sentence}.")
      end

      def dry_run(document, params, _upload)
        # The importer validates every row, then saves a snapshot; the workflow
        # rolls that save back, so the checks are real and nothing is kept.
        export = build(document, params)
        outcome('The export passed every check. Approving saves it as a portal snapshot; no sale or ledger entry is created.',
          counts: { 'Transactions' => export.records.size, 'Kind' => export.kind })
      end

      def import!(document, params, _upload, actor:)
        export = build(document, params)
        outcome('Portal export saved.', counts: { 'Transactions' => export.records.size }, path: helpers.authorize_net_portal_exports_path)
      end

      private

      def build(document, params)
        ::AuthorizeNetPortalImporter.import!(text: text!(document), gateway_id: params['gateway_id'], kind: params['kind'], exported_at: params['exported_at'])
      end
    end
  end
end
