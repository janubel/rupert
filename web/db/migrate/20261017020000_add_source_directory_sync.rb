# frozen_string_literal: true

class AddSourceDirectorySync < ActiveRecord::Migration[8.1]
  def change
    add_column :customers, :source_synced_at, :datetime
    add_column :employees, :source, :string
    add_column :employees, :external_id, :string
    add_column :employees, :source_synced_at, :datetime
    add_column :employees, :source_active, :boolean
    add_index :employees, %i[tenant_id source external_id], unique: true, name: 'idx_employees_source_identity'
    create_table :directory_sync_states do |t|
      t.string :tenant_id, null: false
      t.string :provider, null: false
      t.string :kind, null: false
      t.string :status, null: false, default: 'pending'
      t.string :attempt_token
      t.integer :record_count
      t.datetime :started_at
      t.datetime :finished_at
      t.datetime :last_success_at
      t.string :error
      t.timestamps
      t.index %i[tenant_id provider kind], unique: true, name: 'idx_directory_sync_identity'
    end
    add_foreign_key :directory_sync_states, :tenants
  end
end
