class CreateSyncAttempts < ActiveRecord::Migration[8.1]
  def change
    create_table :sync_attempts do |t|
      t.string :tenant_id
      t.string :source, null: false
      t.string :operation, null: false
      t.string :status, null: false
      t.string :error_category
      t.string :active_job_id
      t.datetime :queued_at, null: false
      t.datetime :started_at
      t.datetime :finished_at
      t.timestamps
    end
    add_foreign_key :sync_attempts, :tenants, on_delete: :cascade
    add_index :sync_attempts, [:tenant_id, :source, :operation, :queued_at], name: 'idx_sync_attempts_source_history'
    add_index :sync_attempts, :active_job_id
  end
end
