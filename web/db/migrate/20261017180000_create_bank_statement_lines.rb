# frozen_string_literal: true

# One row per line of an uploaded bank statement, so a person can decide what
# each line is (expense, vendor payment, ignore) and Rupert never imports the
# same line twice. The statement file itself is kept as a retained original.
class CreateBankStatementLines < ActiveRecord::Migration[8.1]
  def change
    create_table :bank_statement_lines do |t|
      t.string :tenant_id, null: false
      t.integer :document_id, null: false
      t.string :account_label, null: false
      t.integer :line_no, null: false
      t.date :posted_on, null: false
      t.text :description, null: false
      t.integer :amount_cents, null: false
      t.string :fingerprint, null: false
      t.string :status, null: false, default: 'pending'
      t.integer :expense_id
      t.integer :vendor_payment_id
      t.integer :decided_by_id
      t.string :decided_by_name
      t.datetime :decided_at
      t.datetime :created_at, null: false
      t.index %i[tenant_id fingerprint], unique: true, name: 'idx_bank_lines_fingerprint'
      t.index %i[tenant_id document_id status], name: 'idx_bank_lines_document'
      t.index :tenant_id
    end
  end
end
