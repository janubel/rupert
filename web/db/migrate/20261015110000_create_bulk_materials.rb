# frozen_string_literal: true

class CreateBulkMaterials < ActiveRecord::Migration[8.1]
  def change
    create_table :bulk_materials do |t|
      t.string :tenant_id, null: false
      t.string :name, null: false
      t.string :unit, null: false, default: 'g'
      t.timestamps
    end
    add_index :bulk_materials, %i[tenant_id name], unique: true

    create_table :bulk_lots do |t|
      t.string :tenant_id, null: false
      t.references :bulk_material, null: false, foreign_key: true, index: false
      t.string :code, null: false
      t.string :note
      t.string :receipt_token, null: false
      t.bigint :balance_mg, null: false, default: 0
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    add_index :bulk_lots, %i[tenant_id bulk_material_id code], unique: true, name: 'idx_bulk_lots_material_code'
    add_index :bulk_lots, %i[tenant_id receipt_token], unique: true
    add_check_constraint :bulk_lots, 'balance_mg >= 0', name: 'bulk_lots_nonnegative_balance'

    create_table :bulk_movements do |t|
      t.string :tenant_id, null: false
      t.references :bulk_lot, null: false, foreign_key: true, index: false
      t.string :kind, null: false
      t.bigint :delta_mg, null: false
      t.string :input_quantity, null: false
      t.string :input_unit, null: false
      t.string :reference, null: false
      t.string :request_token, null: false
      t.string :created_by, null: false
      t.datetime :created_at, null: false
    end
    add_index :bulk_movements, %i[tenant_id request_token], unique: true
    add_index :bulk_movements, %i[tenant_id bulk_lot_id created_at id], name: 'idx_bulk_movements_lot_timeline'
    add_check_constraint :bulk_movements, 'delta_mg <> 0', name: 'bulk_movements_nonzero'
    add_check_constraint :bulk_movements,
      "(kind = 'receipt' AND delta_mg > 0) OR (kind = 'consume' AND delta_mg < 0) OR kind = 'adjustment'",
      name: 'bulk_movements_kind_sign'
  end
end
