# frozen_string_literal: true

module TeamChat
  # Moves the Drive copies of a deleted message's files to the Drive trash.
  class DriveTrashJob < ApplicationJob
    queue_as :default

    def perform(tenant_id, drive_file_ids)
      Current.tenant = Tenant.find_by(id: tenant_id)
      return unless Current.tenant && DriveStore.available?

      DriveStore.new.trash(Array(drive_file_ids))
    rescue DriveStore::Error, Google::Apis::Error, Signet::AuthorizationError => e
      Rails.logger.warn("[TeamChat::Drive] trash failed: #{e.class}")
    ensure
      Current.reset
    end
  end
end
