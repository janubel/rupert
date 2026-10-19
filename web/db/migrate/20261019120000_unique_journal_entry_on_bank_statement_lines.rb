# frozen_string_literal: true

# Enforce at most one bank statement line per general-ledger entry at the
# database level. The reconciliation workbench links a line to the entry it
# reconciles to; without this, a single entry could be confirmed against two
# lines (inflating "matched" while the ledger counts once). A model validation
# gives the friendly error; this partial unique index is the backstop and also
# covers the recorded-source path. Existing rows already satisfy it (verified:
# no duplicate journal_entry_id at deploy time), so the index builds cleanly.
class UniqueJournalEntryOnBankStatementLines < ActiveRecord::Migration[8.1]
  def change
    remove_index :bank_statement_lines, name: 'idx_bank_lines_journal_entry'
    add_index :bank_statement_lines, :journal_entry_id, unique: true,
      where: 'journal_entry_id IS NOT NULL', name: 'idx_bank_lines_journal_entry_unique'
  end
end
