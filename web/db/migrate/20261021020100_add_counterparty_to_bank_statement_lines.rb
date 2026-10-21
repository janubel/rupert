# frozen_string_literal: true

class AddCounterpartyToBankStatementLines < ActiveRecord::Migration[8.1]
  def change
    # Who a deposit came from (or who a payment went to), typed by a person.
    # Encrypted at rest like the description.
    add_column :bank_statement_lines, :counterparty, :text
  end
end
