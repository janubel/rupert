# frozen_string_literal: true

# Append-only, hash-chained ledger of human approvals of the books for a day or
# week. Rows are never updated or deleted by the application.
class CreateBookApprovals < ActiveRecord::Migration[8.1]
  def change
    create_table :book_approvals do |t|
      t.string :tenant_id, null: false
      t.string :period_kind, null: false
      t.date :period_from, null: false
      t.date :period_to, null: false
      t.string :status, null: false
      t.string :report_digest, null: false
      t.text :summary_json, null: false
      t.text :notes
      t.integer :approved_by_id
      t.string :approved_by_name, null: false
      t.datetime :approved_at, null: false
      t.string :ip
      t.string :user_agent
      t.string :prev_hash, null: false
      t.string :entry_hash, null: false
      t.datetime :created_at, null: false
      t.index %i[tenant_id period_kind period_from], name: 'idx_book_approvals_period'
      t.index :entry_hash, unique: true, name: 'idx_book_approvals_entry_hash'
      t.index :approved_by_id
      t.index :tenant_id
    end
  end
end
