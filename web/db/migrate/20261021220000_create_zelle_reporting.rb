# frozen_string_literal: true

# Manual Zelle (bank-statement) evidence. Zelle has no merchant API and Rupert
# never signs in to a bank, so these tables only hold operator-supplied CSV
# files. They are independent of SwipeSimple, Core::Order and the ledger.
class CreateZelleReporting < ActiveRecord::Migration[8.1]
  def change
    create_table :zelle_exports do |t|
      t.string :tenant_id, null: false
      t.string :account_label, null: false
      t.string :currency, null: false
      t.string :fingerprint, null: false
      t.string :sha256, null: false
      t.datetime :exported_at, null: false
      t.date :first_posted_on
      t.date :last_posted_on
      t.integer :row_count, null: false, default: 0
      t.text :original_csv, null: false
      t.references :imported_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.timestamps
    end
    add_index :zelle_exports, %i[tenant_id fingerprint], unique: true
    add_index :zelle_exports, %i[tenant_id account_label exported_at], name: 'idx_zelle_export_scope'

    create_table :zelle_entries do |t|
      t.string :tenant_id, null: false
      t.references :zelle_export, null: false, foreign_key: true
      t.string :identity, null: false
      t.text :bank_reference, null: false
      t.text :counterparty
      t.text :memo
      t.string :direction, null: false
      t.string :tender, null: false, default: 'zelle'
      t.string :verification, null: false, default: 'unverified'
      t.integer :amount_cents, null: false
      t.date :posted_on, null: false
      t.integer :source_row, null: false
    end
    add_index :zelle_entries, %i[zelle_export_id identity], unique: true, name: 'idx_zelle_export_identity'
    add_index :zelle_entries, %i[tenant_id identity], name: 'idx_zelle_tenant_identity'
    add_index :zelle_entries, %i[tenant_id posted_on], name: 'idx_zelle_tenant_day'
  end
end
