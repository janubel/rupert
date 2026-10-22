# frozen_string_literal: true

module TeamChat
  # Copies one team chat file to the workspace's Google Drive. A failure is
  # recorded on the attachment; the daily sweep tries again.
  class AttachmentDriveJob < ApplicationJob
    queue_as :default

    def perform(attachment_id)
      attachment = Attachment.unscoped.find_by(id: attachment_id)
      return unless attachment && attachment.drive_status != 'stored'

      Current.tenant = Tenant.find_by(id: attachment.tenant_id)
      return unless DriveStore.available?

      DriveStore.new.store!(Attachment.find(attachment.id))
    rescue DriveStore::Error, Google::Apis::Error, Signet::AuthorizationError, SystemCallError, IOError => e
      attachment&.update_columns(drive_status: 'failed', drive_error: e.message.to_s.first(200), updated_at: Time.current)
      Rails.logger.warn("[TeamChat::Drive] #{e.class}: #{e.message.to_s.first(160)}")
    ensure
      Current.reset
    end
  end
end
