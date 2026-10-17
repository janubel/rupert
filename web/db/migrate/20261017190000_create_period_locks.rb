# frozen_string_literal: true

# Append-only, hash-chained ledger of month / quarter / year locks and
# unlocks. The latest event for a period decides whether it is locked. Rows
# are never updated or deleted by the application.
class CreatePeriodLocks < ActiveRecord::Migration[8.1]
  def change
    create_table :period_locks do |t|
      t.string :tenant_id, null: false
      t.string :action, null: false
      t.string :period_kind, null: false
      t.date :period_from, null: false
      t.date :period_to, null: false
      t.string :fingerprint, null: false
      t.text :summary_json, null: false
      t.text :reason
      t.integer :archive_document_id
      t.integer :actor_id
      t.string :actor_name, null: false
      t.datetime :acted_at, null: false
      t.string :ip
      t.string :user_agent
      t.string :prev_hash, null: false
      t.string :entry_hash, null: false
      t.datetime :created_at, null: false
      t.index %i[tenant_id period_kind period_from], name: 'idx_period_locks_period'
      t.index %i[tenant_id period_from period_to], name: 'idx_period_locks_range'
      t.index :entry_hash, unique: true, name: 'idx_period_locks_entry_hash'
      t.index :tenant_id
    end
  end
end
