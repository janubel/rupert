# frozen_string_literal: true

# Optional explicit GL account on an expense. When blank, Finance::Posting maps
# the expense category to a default account, so existing rows keep working and
# this column only needs a backfill for reporting/UX, not for posting.
class AddAccountToExpenses < ActiveRecord::Migration[8.1]
  def up
    add_column :expenses, :account_id, :bigint
    add_index :expenses, :account_id, name: 'idx_expenses_account'
  end

  def down
    remove_index :expenses, name: 'idx_expenses_account'
    remove_column :expenses, :account_id
  end
end
