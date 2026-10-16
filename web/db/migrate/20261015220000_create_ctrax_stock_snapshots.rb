# frozen_string_literal: true

class CreateCtraxStockSnapshots < ActiveRecord::Migration[8.0]
  def change
    add_column :pos_connections, :hourly_sync_enabled, :boolean, default: false, null: false
    create_table :ctrax_stock_snapshots do |t|
      t.references :tenant, type: :string, null: false, foreign_key: true
      t.string :location_id, null: false
      t.string :api_origin, null: false
      t.string :store_id, null: false
      t.text :records_json, null: false
      t.datetime :captured_at, null: false
      t.timestamps
    end
    add_index :ctrax_stock_snapshots, %i[tenant_id location_id], unique: true
    add_foreign_key :ctrax_stock_snapshots, 'Location', column: :location_id, on_delete: :cascade
  end
end
