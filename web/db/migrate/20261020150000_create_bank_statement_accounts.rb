# frozen_string_literal: true

class CreateBankStatementAccounts < ActiveRecord::Migration[8.1]
  def up
    create_table :bank_statement_accounts do |t|
      t.references :tenant, type: :string, null: false, foreign_key: true
      t.string :account_label, null: false
      t.references :ledger_account, null: false, foreign_key: { to_table: :accounts }
      t.timestamps
    end
    add_index :bank_statement_accounts, %i[tenant_id account_label], unique: true, name: 'idx_bank_account_labels'
    add_index :bank_statement_accounts, %i[tenant_id ledger_account_id], unique: true, name: 'idx_bank_account_ledgers'
    remove_index :bank_statement_lines, name: 'idx_bank_lines_journal_entry_unique'
    add_index :bank_statement_lines, %i[tenant_id account_label journal_entry_id], unique: true,
      where: 'journal_entry_id IS NOT NULL', name: 'idx_bank_lines_account_journal_unique'
  end

  def down
    duplicates = select_value('SELECT 1 FROM bank_statement_lines WHERE journal_entry_id IS NOT NULL GROUP BY journal_entry_id HAVING COUNT(*) > 1 LIMIT 1')
    if duplicates
      raise ActiveRecord::IrreversibleMigration, 'An entry is reconciled across bank accounts. Preserve those matches; restore the compatible application instead of removing this migration.'
    end

    remove_index :bank_statement_lines, name: 'idx_bank_lines_account_journal_unique'
    add_index :bank_statement_lines, :journal_entry_id, unique: true,
      where: 'journal_entry_id IS NOT NULL', name: 'idx_bank_lines_journal_entry_unique'
    drop_table :bank_statement_accounts
  end
end
