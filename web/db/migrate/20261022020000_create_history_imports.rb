# frozen_string_literal: true

# Retained, reviewable imports of outside accounting exports (QuickBooks first).
# Nothing here changes a business record by itself: a file is kept byte for byte,
# parsed into staged lines with stable fingerprints, and only an operator's
# approval turns staged transactions into journal entries.
class CreateHistoryImports < ActiveRecord::Migration[8.1]
  def up
    # The original file, unchanged. Unlike ReconciliationDocument there is no
    # 366-day period limit: an accounting export can span several years.
    create_table :import_source_documents do |t|
      t.string :tenant_id, null: false
      t.string :source, null: false
      t.string :kind, null: false
      t.string :filename, null: false
      t.string :content_type, null: false
      t.integer :byte_size, null: false
      t.string :sha256, null: false
      t.text :content_base64, null: false
      t.integer :uploaded_by_id
      t.datetime :created_at, null: false
      t.index %i[tenant_id source sha256], unique: true, name: 'idx_import_documents_replay'
      t.index :tenant_id
    end

    create_table :import_batches do |t|
      t.string :tenant_id, null: false
      t.string :source, null: false
      t.string :kind, null: false
      t.string :status, null: false, default: 'staged'
      t.integer :source_document_id, null: false
      t.string :filename, null: false
      t.date :date_from
      t.date :date_to
      t.date :as_of
      t.integer :row_count, null: false, default: 0
      t.integer :transaction_count, null: false, default: 0
      t.integer :accepted_count, null: false, default: 0
      t.integer :duplicate_count, null: false, default: 0
      t.integer :rejected_count, null: false, default: 0
      t.text :summary_json, null: false
      t.date :post_through
      t.integer :created_by_id
      t.string :created_by_name
      t.integer :approved_by_id
      t.string :approved_by_name
      t.datetime :approved_at
      t.string :closed_by_name
      t.datetime :closed_at
      t.text :closed_reason
      t.timestamps
      t.index %i[tenant_id source status], name: 'idx_import_batches_status'
      t.index %i[tenant_id created_at], name: 'idx_import_batches_recent'
      t.index :source_document_id
      t.index :tenant_id
    end

    # One accounting transaction (several lines that must balance). Its
    # journal_entry_id is the link from the imported record back to the source.
    create_table :import_transactions do |t|
      t.string :tenant_id, null: false
      t.integer :batch_id, null: false
      t.string :txn_key, null: false
      t.date :txn_date, null: false
      t.string :txn_type
      t.string :doc_number
      t.text :name
      t.integer :line_count, null: false, default: 0
      t.bigint :debit_cents, null: false, default: 0
      t.bigint :credit_cents, null: false, default: 0
      t.string :fingerprint, null: false
      t.string :status, null: false, default: 'staged'
      t.text :reason
      t.bigint :journal_entry_id
      t.datetime :posted_at
      t.timestamps
      t.index %i[tenant_id fingerprint], unique: true, where: "status IN ('staged', 'posted')", name: 'idx_import_txn_live_fingerprint'
      t.index %i[tenant_id batch_id status], name: 'idx_import_txn_batch'
      t.index %i[tenant_id txn_date], name: 'idx_import_txn_date'
      t.index :journal_entry_id
      t.index :tenant_id
    end

    # One parsed row. record_type says what it is: a transaction line, an
    # account, vendor or customer from a list, or a trial-balance row that is
    # kept only to reconcile against Rupert's own books.
    create_table :import_lines do |t|
      t.string :tenant_id, null: false
      t.integer :batch_id, null: false
      t.integer :transaction_id
      t.integer :row_no, null: false
      t.string :record_type, null: false
      t.string :fingerprint, null: false
      t.string :status, null: false, default: 'staged'
      t.text :reason
      t.date :txn_date
      t.string :txn_type
      t.string :doc_number
      t.text :name
      t.text :memo
      t.string :account_name
      t.string :account_number
      t.string :account_type
      t.string :class_name
      t.string :location_name
      t.bigint :debit_cents, null: false, default: 0
      t.bigint :credit_cents, null: false, default: 0
      t.text :raw_json
      t.timestamps
      t.index %i[tenant_id fingerprint], unique: true, where: "status IN ('staged', 'posted')", name: 'idx_import_lines_live_fingerprint'
      t.index %i[tenant_id batch_id status], name: 'idx_import_lines_batch'
      t.index %i[tenant_id batch_id row_no], name: 'idx_import_lines_row'
      t.index :transaction_id
      t.index :tenant_id
    end

    # The operator's explicit, reviewable decision for each outside account,
    # vendor or customer. Nothing is mapped by guesswork.
    create_table :import_entity_mappings do |t|
      t.string :tenant_id, null: false
      t.string :source, null: false
      t.string :entity_type, null: false
      t.string :source_key, null: false
      t.string :source_name, null: false
      t.string :source_number
      t.string :source_type
      t.string :decision, null: false, default: 'unmapped'
      t.integer :target_id
      t.string :proposed_code
      t.string :proposed_type
      t.integer :first_batch_id
      t.integer :decided_by_id
      t.string :decided_by_name
      t.datetime :decided_at
      t.timestamps
      t.index %i[tenant_id source entity_type source_key], unique: true, name: 'idx_import_mappings_key'
      t.index %i[tenant_id entity_type target_id], name: 'idx_import_mappings_target'
      t.index :tenant_id
    end
  end

  def down
    kept = select_value('SELECT 1 FROM import_source_documents LIMIT 1')
    if kept
      raise ActiveRecord::IrreversibleMigration, 'Imported originals, staged lines and mappings are retained evidence. ' \
                                                  'Preserve them; restore the compatible application instead of removing this migration.'
    end

    drop_table :import_entity_mappings
    drop_table :import_lines
    drop_table :import_transactions
    drop_table :import_batches
    drop_table :import_source_documents
  end
end
