# frozen_string_literal: true

# Team chat files are copied to the workspace's own Google Drive (the Document
# retention connection). After the copy is verified and has been kept here a
# while, Rupert's copy is dropped and the file is served from Drive.
class AddDriveStorageToTeamChat < ActiveRecord::Migration[8.1]
  def change
    add_column :chat_attachments, :drive_file_id, :string
    add_column :chat_attachments, :drive_status, :string, null: false, default: 'local'
    add_column :chat_attachments, :drive_md5, :string
    add_column :chat_attachments, :drive_stored_at, :datetime
    add_column :chat_attachments, :drive_error, :string
    change_column_null :chat_attachments, :data, true
    add_index :chat_attachments, %i[tenant_id drive_status]
    add_column :chat_rooms, :drive_folder_id, :string
  end
end
