# frozen_string_literal: true

class CreateMoneyReconciliations < ActiveRecord::Migration[8.1]
  def change
    create_table :money_reconciliations do |t|
      t.string :tenant_id, null: false
      t.string :period_kind, null: false
      t.date :period_from, null: false
      t.date :period_to, null: false
      t.datetime :generated_at, null: false
      t.text :payload_json, null: false
      t.timestamps
    end
    add_index :money_reconciliations, [:tenant_id, :period_kind, :period_from], unique: true, name: 'idx_money_reconciliation_period'
  end
end
