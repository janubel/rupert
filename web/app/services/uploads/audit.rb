# frozen_string_literal: true

module Uploads
  # The only place the inbox writes to the application log and the activity trail.
  # It records what happened and to which file by hash, size, format, type and
  # outcome. File contents, cell values and parameters never reach a log line.
  module Audit
    FIELDS = %w[id sha256 byte_size file_format detected_type status origin].freeze

    def self.record(event, upload, actor: Current.user, detail: nil)
      line = FIELDS.map { |field| "#{field}=#{upload.public_send(field).to_s.gsub(/[^\w:.-]/, '?').first(80)}" }
      line << "event=#{event}"
      line << "outcome=#{outcome(upload)}"
      Rails.logger.info("[uploads] #{line.join(' ')}")
      ActivityLogger.log("upload_#{event}", subject: upload, actor: actor,
        details: [("sha256=#{upload.sha256.to_s.first(12)}" if upload.sha256), "bytes=#{upload.byte_size}", "origin=#{upload.origin}", "status=#{upload.status}", detail].compact.join('; '))
    end

    def self.outcome(upload)
      upload.reason.present? && upload.status == 'rejected' ? 'rejected' : upload.status
    end
  end
end
