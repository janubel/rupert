# frozen_string_literal: true

class CreateExpenseCategories < ActiveRecord::Migration[8.1]
  def change
    create_table :expense_categories do |t|
      t.string :tenant_id, null: false
      t.string :key, null: false
      t.string :name, null: false
      t.bigint :ledger_account_id
      t.text :keywords
      t.boolean :active, null: false, default: true
      t.boolean :built_in, null: false, default: false
      t.integer :position, null: false, default: 0
      t.timestamps
    end
    add_index :expense_categories, %i[tenant_id key], unique: true, name: 'idx_expense_categories_key'
  end
end
