# frozen_string_literal: true

module Uploads
  # The only place the inbox writes to the application log (an OpsLog `upload` event) and the activity trail.
  # It records what happened and to which file by hash, size, format, type and
  # outcome. File contents, cell values and parameters never reach a log line.
  module Audit
    FIELDS = %w[id sha256 byte_size file_format detected_type status origin].freeze

    def self.record(event, upload, actor: Current.user, detail: nil)
      facts = FIELDS.to_h { |field| [field.to_sym, upload.public_send(field).to_s.gsub(/[^\w:.-]/, '?').first(80)] }
      OpsLog.event('upload', level: outcome(upload) == 'rejected' ? :warn : :info, action: event, outcome: outcome(upload), **facts,
        user_id: actor&.id, tenant_id: Current.tenant_id, persist: OpsLog.context[:request_id].nil?)
      ActivityLogger.log("upload_#{event}", subject: upload, actor: actor,
        details: [("sha256=#{upload.sha256.to_s.first(12)}" if upload.sha256), "bytes=#{upload.byte_size}", "origin=#{upload.origin}", "status=#{upload.status}", detail].compact.join('; '))
    end

    def self.outcome(upload)
      upload.reason.present? && upload.status == 'rejected' ? 'rejected' : upload.status
    end
  end
end
