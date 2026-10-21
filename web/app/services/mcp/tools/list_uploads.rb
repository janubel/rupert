# frozen_string_literal: true

module Mcp
  module Tools
    class ListUploads < Tool
      tool 'list_uploads',
        title: 'List uploaded files',
        description: 'Answers "did my file arrive and what happened to it?" from the Uploads inbox: each file\'s name, status ' \
                     '(received, recognized, needs_review, imported, rejected, duplicate), who sent it and when, size, SHA-256, what ' \
                     'Rupert thinks it is with a confidence, the reason for any rejection or hold, and whether it was imported. ' \
                     'Find a file by id, file-name fragment or SHA-256 prefix. Never returns file contents. Read-only: it cannot ' \
                     'upload or approve anything.',
        scope: 'uploads:read'

      input_schema(
        type: 'object',
        properties: {
          id: { type: 'integer', minimum: 1, description: 'One upload by id.' },
          query: { type: 'string', maxLength: 80, description: 'Part of the file name.' },
          sha256: { type: 'string', maxLength: 64, description: 'Full SHA-256 or its first 6 or more hex characters.' },
          status: { type: 'string', enum: Upload::STATUSES, description: 'Only uploads in this status.' },
          **PAGE_PROPERTIES
        },
        additionalProperties: false
      )

      def call(args)
        scope = Upload.newest_first
        scope = scope.where(id: args['id']) if args['id']
        scope = scope.where(status: args['status']) if args['status']
        scope = scope.where('filename LIKE ?', "%#{Upload.sanitize_sql_like(args['query'].strip)}%") if args['query'].present?
        if args['sha256'].present?
          prefix = args['sha256'].strip.downcase
          raise ToolError.new('sha256 must be at least 6 hexadecimal characters.', kind: 'invalid_arguments') unless prefix.match?(/\A\h{6,64}\z/)

          scope = scope.where('sha256 LIKE ?', "#{prefix}%")
        end
        uploads, meta = paginate(scope, args, default_per_page: 10)
        counts = Upload.group(:status).count
        rows = uploads.map { |upload| row(upload) }
        text = "#{counts.values.sum} uploads in total (#{Upload::STATUSES.filter_map { |status| "#{counts[status]} #{status.tr('_', ' ')}" if counts[status] }.join(', ').presence || 'none yet'}). " \
               "#{rows.empty? ? 'No upload matches.' : rows.first(5).map { |r| "#{r[:filename]}: #{r[:status]}#{" — #{r[:note]}" if r[:note]}" }.join('; ')}"
        result(text, { counts: counts, rows: rows, meta: meta })
      end

      private

      def row(upload)
        { id: upload.id, filename: upload.filename, status: upload.status, note: upload.reason.presence || UploadsHelper::STATUS_HELP[upload.status],
          origin: upload.origin, uploaded_by: upload.uploaded_by_name, received_at: iso(upload.created_at), byte_size: upload.byte_size,
          sha256: upload.sha256, format: upload.file_format, detected_type: upload.detected_label, confidence: upload.confidence,
          importer: upload.importer_key, lines: upload.row_count, duplicate_of_id: upload.duplicate_of_id, imported_at: iso(upload.imported_at),
          imported_by: upload.imported_by_name, path: "/uploads/#{upload.id}" }
      end
    end
  end
end
