# frozen_string_literal: true

module Api
  module V1
    # Send a file to the Uploads inbox without the web UI:
    #
    #   curl -H "Authorization: Bearer rupert_..." -F file=@statement.csv https://HOST/api/v1/uploads
    #
    # POST needs the uploads:write scope, GET needs uploads:read. A token can
    # receive files but can never approve an import: approval stays a person's
    # decision in the app. Responses carry ids, hashes, statuses and plain-language
    # reasons, never file contents.
    class UploadsController < BaseController
      def create
        return unless require_scope('uploads:write')

        return render_error(413, 'too_large', "A request may carry at most #{Uploads::Limits::MAX_REQUEST_BYTES / 1.megabyte} MiB.") if request.content_length.to_i > Uploads::Limits::MAX_REQUEST_BYTES + 65_536

        files = submitted_files
        return render_error(400, 'no_file', 'Send the file as multipart form data in a field named file, for example: -F file=@statement.csv') if files.empty?
        return render_error(400, 'too_many_files', "Send up to #{Uploads::Limits::MAX_FILES_PER_REQUEST} files per request.") if files.size > Uploads::Limits::MAX_FILES_PER_REQUEST

        results = files.map do |file|
          Uploads::Intake.call(file, filename: file.original_filename, content_type: file.content_type, origin: 'api', actor: Current.user, token_label: @api_token.name)
        end
        status = results.all? { |result| result.upload.status == 'rejected' } ? :unprocessable_entity : (results.any?(&:created) ? :created : :ok)
        render json: { data: results.map { |result| serialize(result.upload) }, meta: { api_version: 'v1', received: results.count(&:created) } }, status: status
      rescue Uploads::Intake::Error => e
        render_error(429, 'limit_reached', e.message)
      end

      def index
        return unless require_scope('uploads:read')

        scope = Upload.newest_first
        scope = scope.where(status: params[:status]) if Upload::STATUSES.include?(params[:status].to_s)
        scope = scope.where(sha256: params[:sha256].to_s.downcase) if params[:sha256].to_s.match?(/\A\h{64}\z/)
        render_page(scope) { |upload| serialize(upload) }
      end

      def show
        return unless require_scope('uploads:read')

        render json: { data: serialize(Upload.find(params[:id])), meta: { api_version: 'v1' } }
      end

      private

      def submitted_files
        (Array(params[:files]) + Array(params[:file])).grep(ActionDispatch::Http::UploadedFile)
      end

      def serialize(upload)
        { id: upload.id, filename: upload.filename, status: upload.status, status_text: upload.reason.presence || UploadsHelper::STATUS_HELP[upload.status],
          origin: upload.origin, sha256: upload.sha256, byte_size: upload.byte_size, format: upload.file_format,
          detected_type: upload.detected_type, detected_label: upload.detected_label, confidence: upload.confidence, importer: upload.importer_key,
          lines: upload.row_count, duplicate_of_id: upload.duplicate_of_id, received_at: upload.created_at.iso8601, imported_at: upload.imported_at&.iso8601,
          uploaded_by: upload.uploaded_by_name, review_url: "/uploads/#{upload.id}" }
      end

      def render_error(status, code, message)
        render json: { error: { code: code, message: message } }, status: status
      end
    end
  end
end
