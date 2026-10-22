# frozen_string_literal: true

# A workspace's read-only Google Drive link for fetching files into the Uploads
# inbox. The token is its own (never the backup or retention token) and only the
# folder a person chose is ever listed or read.
class CreateImportDriveConnections < ActiveRecord::Migration[8.1]
  def change
    create_table :import_drive_connections do |t|
      t.string :tenant_id, null: false
      t.text :refresh_token
      t.text :account_email
      t.string :folder_id
      t.text :folder_name
      t.integer :connected_by_id
      t.datetime :last_listed_at
      t.text :last_error
      t.timestamps
      t.index :tenant_id, unique: true
    end
  end
end
