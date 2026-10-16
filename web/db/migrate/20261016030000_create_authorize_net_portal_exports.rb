# frozen_string_literal: true

class CreateAuthorizeNetPortalExports < ActiveRecord::Migration[8.1]
  def change
    create_table :authorize_net_portal_exports do |t|
      t.references :tenant, type: :string, null: false, foreign_key: true
      t.string :gateway_id, null: false
      t.string :kind, null: false
      t.string :fingerprint, null: false
      t.string :sha256, null: false
      t.datetime :exported_at, null: false
      t.text :original_csv, null: false
      t.text :records_json, null: false
      t.timestamps
    end
    add_index :authorize_net_portal_exports, %i[tenant_id fingerprint], unique: true, name: 'idx_anet_portal_fingerprint'
  end
end
