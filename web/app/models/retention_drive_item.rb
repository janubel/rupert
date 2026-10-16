# frozen_string_literal: true

class RetentionDriveItem < ApplicationRecord
  include TenantScoped
  encrypts :display_name
  encrypts :folder_path
  validates :tenant_id, :generation, :item_key, presence: true
  validates :status, inclusion: { in: %w[pending verified failed] }

  def folder?
    item_key.start_with?('folder:')
  end

  def drive_url
    return if remote_id.blank? || status != 'verified'

    folder? ? "https://drive.google.com/drive/folders/#{remote_id}" : "https://drive.google.com/file/d/#{remote_id}/view"
  end
end
