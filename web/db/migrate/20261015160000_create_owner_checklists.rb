# frozen_string_literal: true

class CreateOwnerChecklists < ActiveRecord::Migration[8.1]
  def change
    create_table :owner_checklists do |t|
      t.string :tenant_id, null: false
      t.text :payload_json, null: false
      t.integer :lock_version, null: false, default: 0
      t.references :created_by, foreign_key: { to_table: :users, on_delete: :nullify }, index: false
      t.references :updated_by, foreign_key: { to_table: :users, on_delete: :nullify }, index: false
      t.timestamps
    end
    add_index :owner_checklists, %i[tenant_id created_at id], name: 'idx_owner_checklists_timeline'

    create_table :owner_checklist_events do |t|
      t.string :tenant_id, null: false
      t.references :owner_checklist, null: false, foreign_key: true, index: false
      t.references :actor, foreign_key: { to_table: :users, on_delete: :nullify }, index: false
      t.text :payload_json, null: false
      t.string :action, null: false
      t.datetime :created_at, null: false
    end
    add_index :owner_checklist_events, %i[tenant_id owner_checklist_id created_at id], name: 'idx_owner_checklist_events_timeline'
  end
end
