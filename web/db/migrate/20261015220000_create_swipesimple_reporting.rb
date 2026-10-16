# frozen_string_literal: true

class CreateSwipesimpleReporting < ActiveRecord::Migration[8.1]
  def change
    create_table :swipesimple_exports do |t|
      t.string :tenant_id, null: false
      t.string :merchant_account, null: false
      t.string :kind, null: false
      t.string :currency, null: false
      t.string :source_timezone, null: false
      t.string :fingerprint, null: false
      t.string :sha256, null: false
      t.datetime :exported_at, null: false
      t.text :original_csv, null: false
      t.references :imported_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.timestamps
    end
    add_index :swipesimple_exports, %i[tenant_id fingerprint], unique: true
    add_index :swipesimple_exports, %i[tenant_id merchant_account kind exported_at id], name: 'idx_swipesimple_snapshot_scope'

    create_table :swipesimple_report_rows do |t|
      t.string :tenant_id, null: false
      t.references :swipesimple_export, null: false, foreign_key: true
      t.string :identity, null: false
      t.text :source_number, null: false
      t.string :transaction_type
      t.string :status, null: false
      t.string :tender
      t.integer :amount_cents, null: false
      t.integer :tip_cents
      t.datetime :occurred_at, null: false
      t.text :reference_number
      t.date :due_on
      t.datetime :last_sent_at
      t.integer :source_row, null: false
    end
    add_index :swipesimple_report_rows, %i[swipesimple_export_id identity], unique: true, name: 'idx_swipesimple_export_identity'
    add_index :swipesimple_report_rows, %i[tenant_id identity], name: 'idx_swipesimple_tenant_identity'
  end
end
