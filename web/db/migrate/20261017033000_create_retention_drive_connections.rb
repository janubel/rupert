# frozen_string_literal: true

class CreateRetentionDriveConnections < ActiveRecord::Migration[8.0]
  def change
    create_table :retention_drive_connections do |t|
      t.string :tenant_id, null: false
      t.text :refresh_token
      t.text :account_email
      t.string :generation
      t.boolean :enabled, null: false, default: false
      t.string :sync_lease_token
      t.datetime :sync_lease_at
      t.datetime :last_synced_at
      t.text :last_error
      t.timestamps
    end
    add_index :retention_drive_connections, :tenant_id, unique: true
    add_foreign_key :retention_drive_connections, :tenants
    create_table :retention_drive_items do |t|
      t.string :tenant_id, null: false
      t.string :generation, null: false
      t.string :item_key, null: false
      t.string :remote_id
      t.string :status, null: false, default: 'pending'
      t.string :sha256
      t.bigint :byte_size
      t.text :display_name
      t.text :folder_path
      t.text :last_error
      t.datetime :last_attempt_at
      t.datetime :verified_at
      t.timestamps
    end
    add_index :retention_drive_items, [:tenant_id, :generation, :item_key], unique: true, name: 'index_retention_drive_items_identity'
    add_index :retention_drive_items, [:tenant_id, :generation, :status], name: 'index_retention_drive_items_status'
    add_foreign_key :retention_drive_items, :tenants
  end
end
