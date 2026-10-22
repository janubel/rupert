# frozen_string_literal: true

module TeamChat
  # Daily, per workspace with Google Drive connected: copy files that are not in
  # Drive yet (posted before Drive was connected, or a failed try), and drop
  # Rupert's own copy of files Drive has had, verified, for KEEP_LOCAL_FOR.
  class AttachmentDriveSweepJob < ApplicationJob
    queue_as :default

    BATCH = 200

    def perform
      Tenant.where(status: 'active').find_each do |tenant|
        Current.tenant = tenant
        next unless DriveStore.available?

        Attachment.where(drive_status: [nil, 'local', 'failed']).where.not(data: nil).order(:id).limit(BATCH).pluck(:id)
                  .each { |id| AttachmentDriveJob.perform_later(id) }
        Attachment.where(drive_status: 'stored', drive_stored_at: ...DriveStore::KEEP_LOCAL_FOR.ago).where.not(data: nil)
                  .update_all(data: nil, updated_at: Time.current)
      ensure
        Current.tenant = nil
      end
    end
  end
end
