# frozen_string_literal: true

# Double-entry general ledger (roadmap F39). A journal entry is an immutable,
# balanced record: the sum of its debit lines always equals the sum of its
# credit lines. Every line posts to one chart-of-accounts account. The partial
# unique index keeps at most one *posted* entry per source record, which makes
# posting from expenses/sales/vendor payments idempotent while still allowing a
# voided entry to be superseded by a corrected one.
class CreateJournalEntries < ActiveRecord::Migration[8.1]
  def change
    create_table :journal_entries do |t|
      t.string :tenant_id, null: false
      t.date :posted_on, null: false
      t.string :kind, null: false
      t.string :status, null: false, default: 'posted'
      t.string :source_type
      t.string :source_id
      t.text :memo
      t.integer :created_by_id
      t.datetime :created_at, null: false
      t.datetime :updated_at, null: false
      t.index %i[tenant_id posted_on], name: 'idx_journal_entries_posted_on'
      t.index %i[tenant_id source_type source_id], unique: true, name: 'idx_journal_entries_source', where: "status = 'posted'"
      t.index :tenant_id
    end

    create_table :journal_lines do |t|
      t.string :tenant_id, null: false
      t.bigint :journal_entry_id, null: false
      t.bigint :account_id, null: false
      t.integer :debit_cents, null: false, default: 0
      t.integer :credit_cents, null: false, default: 0
      t.text :memo
      t.integer :position, null: false, default: 0
      t.datetime :created_at, null: false
      t.datetime :updated_at, null: false
      t.index :journal_entry_id, name: 'idx_journal_lines_entry'
      t.index %i[tenant_id account_id], name: 'idx_journal_lines_account'
      t.index :tenant_id
    end
  end
end
