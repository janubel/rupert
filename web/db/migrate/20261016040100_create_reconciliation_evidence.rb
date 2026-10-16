# frozen_string_literal: true

class CreateReconciliationEvidence < ActiveRecord::Migration[8.1]
  def change
    create_table :reconciliation_documents do |t|
      t.references :tenant, type: :string, null: false, foreign_key: true
      t.string :source, null: false
      t.string :kind, null: false
      t.date :period_from, null: false
      t.date :period_to, null: false
      t.text :metadata_json, null: false
      t.text :content_base64, null: false
      t.string :filename, null: false
      t.string :content_type, null: false
      t.string :sha256, null: false
      t.string :fingerprint, null: false
      t.integer :byte_size, null: false
      t.references :uploaded_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.bigint :supersedes_id
      t.datetime :created_at, null: false
    end
    add_index :reconciliation_documents, %i[tenant_id fingerprint], unique: true, name: 'idx_reconciliation_evidence_replay'
    add_index :reconciliation_documents, %i[tenant_id period_from period_to], name: 'idx_reconciliation_evidence_period'
    add_index :reconciliation_documents, %i[tenant_id supersedes_id], unique: true, name: 'idx_reconciliation_evidence_correction'
    add_foreign_key :reconciliation_documents, :reconciliation_documents, column: :supersedes_id

    create_table :daily_reconciliation_reviews do |t|
      t.references :tenant, type: :string, null: false, foreign_key: true
      t.date :day, null: false
      t.string :report_digest, null: false
      t.string :status, null: false
      t.text :notes, null: false
      t.references :reviewed_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.datetime :created_at, null: false
    end
    add_index :daily_reconciliation_reviews, %i[tenant_id day], name: 'idx_daily_reconciliation_review_day'
  end
end
