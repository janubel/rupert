# frozen_string_literal: true

class AddBankLineReviewContext < ActiveRecord::Migration[8.1]
  def change
    add_column :bank_statement_lines, :review_category, :string
    add_column :bank_statement_lines, :review_note, :text
    add_column :bank_statement_lines, :review_flag, :boolean, null: false, default: false
    add_column :bank_statement_lines, :reviewed_at, :datetime
  end
end
