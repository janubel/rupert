# frozen_string_literal: true

# One per workspace. Read-only access to the person's Google Drive, used only to
# copy files from a chosen folder into the Uploads inbox on request.
class ImportDriveConnection < ApplicationRecord
  include TenantScoped

  encrypts :refresh_token
  encrypts :account_email
  encrypts :folder_name
  validates :tenant_id, presence: true, uniqueness: true

  def connected? = refresh_token.present?
  def folder_chosen? = folder_id.present?
end
