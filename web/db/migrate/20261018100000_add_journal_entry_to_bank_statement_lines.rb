# frozen_string_literal: true

# Link a bank statement line to the general-ledger entry it reconciles to
# (roadmap F40). Nullable: most lines start unmatched and a person confirms the
# pairing in the reconciliation workbench.
class AddJournalEntryToBankStatementLines < ActiveRecord::Migration[8.1]
  def up
    add_column :bank_statement_lines, :journal_entry_id, :bigint
    add_index :bank_statement_lines, :journal_entry_id, name: 'idx_bank_lines_journal_entry'
  end

  def down
    remove_index :bank_statement_lines, name: 'idx_bank_lines_journal_entry'
    remove_column :bank_statement_lines, :journal_entry_id
  end
end
