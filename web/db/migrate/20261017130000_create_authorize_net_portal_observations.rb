# frozen_string_literal: true

# Normalizes portal export rows so a day or period reads only the observations
# it can cover. The original row stays encrypted; keys and dates stay queryable.
class CreateAuthorizeNetPortalObservations < ActiveRecord::Migration[8.1]
  class Export < ActiveRecord::Base
    self.table_name = 'authorize_net_portal_exports'
    encrypts :original_csv
    encrypts :records_json
  end

  def up
    unless table_exists?(:authorize_net_portal_observations)
      create_table :authorize_net_portal_observations do |t|
        t.string :tenant_id, null: false
        t.references :authorize_net_portal_export, null: false, index: false, foreign_key: { on_delete: :cascade }
        t.integer :position, null: false
        t.string :gateway_id, null: false
        t.string :transaction_id, null: false
        t.datetime :exported_at, null: false
        t.datetime :submitted_at
        t.datetime :settled_at
        t.string :status
        t.string :transaction_type
        t.string :currency
        t.bigint :settlement_cents
        t.text :record_json, null: false
        t.timestamps
        t.index %i[authorize_net_portal_export_id position], unique: true, name: 'idx_anet_portal_obs_row'
        t.index %i[tenant_id transaction_id gateway_id], name: 'idx_anet_portal_obs_key'
        t.index %i[tenant_id submitted_at], name: 'idx_anet_portal_obs_submitted'
        t.index %i[tenant_id settled_at], name: 'idx_anet_portal_obs_settled'
      end
      add_foreign_key :authorize_net_portal_observations, :tenants
    end
    AuthorizeNetPortalObservation.reset_column_information
    # Idempotent: exports that already have observations are left untouched.
    done = select_values('SELECT DISTINCT authorize_net_portal_export_id FROM authorize_net_portal_observations').to_set(&:to_i)
    Export.find_each do |export|
      next if done.include?(export.id)

      transaction { AuthorizeNetPortalObservation.record!(export) }
    end
  end

  def down
    drop_table :authorize_net_portal_observations, if_exists: true
  end
end
