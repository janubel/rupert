# frozen_string_literal: true

# One whole-instance backup to the platform operator's approved destination.
class BackupJob < ApplicationJob
  queue_as :default

  def perform
    Current.set(tenant: nil, user: nil) do
      GoogleDriveBackupService.backup!(actor: 'scheduler') if GoogleDriveBackupService.connected?
    end
  rescue GoogleDriveBackupService::NotConnectedError
    nil
  end
end
