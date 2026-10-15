# frozen_string_literal: true

class CreatePosConnections < ActiveRecord::Migration[8.1]
  def change
    create_table :pos_connections do |t|
      t.string :tenant_id, null: false
      t.string :provider, null: false
      t.string :environment, null: false, default: 'sandbox'
      t.string :account_reference
      t.string :gateway, null: false, default: 'unconfirmed'
      t.boolean :access_requested, null: false, default: false
      t.boolean :vendor_approved, null: false, default: false
      t.text :credentials_json
      t.string :last_check_status
      t.string :last_check_message
      t.datetime :last_checked_at
      t.references :updated_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    add_index :pos_connections, %i[tenant_id provider], unique: true
    add_foreign_key :pos_connections, :tenants
    add_check_constraint :pos_connections, "environment IN ('sandbox', 'production')", name: 'pos_connection_environment'
    add_check_constraint :pos_connections, "last_check_status IS NULL OR last_check_status IN ('verified', 'failed')", name: 'pos_connection_check_status'
  end
end
