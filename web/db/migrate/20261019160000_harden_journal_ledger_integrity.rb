# frozen_string_literal: true

# Database backstop for the double-entry general ledger (audit issue #167).
#
# The balance and one-sided-line rules previously lived only in the models, so
# a console session, a raw SQL script, a future `insert_all` or a restored dump
# could leave lines pointing at missing entries/accounts or carrying both (or
# neither) a debit and a credit. This adds:
#
# * foreign keys from journal_lines to journal_entries and accounts;
# * a CHECK that every line carries exactly one non-negative, non-zero side;
# * 64-bit amount columns so a large manual entry cannot overflow the prior
#   32-bit integer columns (audit #169 M11).
#
# Per-entry balance (sum of debits = sum of credits) cannot be a row-level
# constraint on SQLite, so it is reported by BooksCheck#ledger_balance instead.
#
# The migration refuses to run, without changing anything, when existing rows
# already violate a rule; repair those rows deliberately first.
class HardenJournalLedgerIntegrity < ActiveRecord::Migration[8.1]
  ONE_SIDED = '(debit_cents >= 0 AND credit_cents >= 0) AND ((debit_cents = 0) <> (credit_cents = 0))'

  def up
    preflight!

    change_column :journal_lines, :debit_cents, :bigint, null: false, default: 0
    change_column :journal_lines, :credit_cents, :bigint, null: false, default: 0
    add_foreign_key :journal_lines, :journal_entries, column: :journal_entry_id, on_delete: :restrict
    add_foreign_key :journal_lines, :accounts, column: :account_id, on_delete: :restrict
    add_check_constraint :journal_lines, ONE_SIDED, name: 'chk_journal_lines_one_sided'
  end

  def down
    remove_check_constraint :journal_lines, name: 'chk_journal_lines_one_sided'
    remove_foreign_key :journal_lines, column: :account_id
    remove_foreign_key :journal_lines, column: :journal_entry_id
    change_column :journal_lines, :debit_cents, :integer, null: false, default: 0
    change_column :journal_lines, :credit_cents, :integer, null: false, default: 0
  end

  private

  def preflight!
    problems = {
      'lines without an existing journal entry' =>
        'SELECT COUNT(*) FROM journal_lines l LEFT JOIN journal_entries e ON e.id = l.journal_entry_id WHERE e.id IS NULL',
      'lines without an existing account' =>
        'SELECT COUNT(*) FROM journal_lines l LEFT JOIN accounts a ON a.id = l.account_id WHERE a.id IS NULL',
      'lines that are not exactly one positive side' =>
        "SELECT COUNT(*) FROM journal_lines WHERE NOT (#{ONE_SIDED})"
    }.filter_map do |label, sql|
      count = select_value(sql).to_i
      "#{count} #{label}" if count.positive?
    end
    return if problems.empty?

    raise ActiveRecord::MigrationError,
      "General ledger has rows that would violate the new constraints (#{problems.join('; ')}). " \
      'Nothing was changed. Repair or void those entries deliberately, then run the migration again.'
  end
end
