# frozen_string_literal: true

class CreateReconciliationFollowUps < ActiveRecord::Migration[8.1]
  def change
    create_table :reconciliation_follow_ups do |t|
      t.references :tenant, type: :string, null: false, foreign_key: true
      t.string :category, null: false
      t.string :source, null: false
      t.string :document_kind, null: false
      t.date :period_from, null: false
      t.date :period_to, null: false
      t.string :currency
      t.string :location_id
      t.string :metric
      t.string :report_digest
      t.text :title, null: false
      t.text :notes, null: false
      t.string :status, null: false, default: 'open'
      t.date :due_on, null: false
      t.references :owner, foreign_key: { to_table: :users, on_delete: :nullify }
      t.references :created_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.references :document, foreign_key: { to_table: :reconciliation_documents }
      t.string :submission_key, null: false
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    add_index :reconciliation_follow_ups, %i[tenant_id status due_on], name: 'idx_reconciliation_follow_up_queue'
    add_index :reconciliation_follow_ups, %i[tenant_id period_from period_to], name: 'idx_reconciliation_follow_up_period'
    add_index :reconciliation_follow_ups, %i[tenant_id submission_key], unique: true, name: 'idx_reconciliation_follow_up_submission'

    create_table :reconciliation_follow_up_events do |t|
      t.references :tenant, type: :string, null: false, foreign_key: true
      t.references :reconciliation_follow_up, null: false, foreign_key: true, index: { name: 'idx_reconciliation_follow_up_history' }
      t.text :details_json, null: false
      t.datetime :created_at, null: false
    end
  end
end
