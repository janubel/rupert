# frozen_string_literal: true

class CreateBulkRecipesAndConsumptions < ActiveRecord::Migration[8.1]
  def change
    create_table :bulk_recipes do |t|
      t.string :tenant_id, null: false
      t.string :source, null: false, default: 'shopify'
      t.string :source_variant_id, null: false
      t.references :bulk_material, null: false, foreign_key: true, index: false
      t.integer :version, null: false
      t.bigint :mg_per_unit, null: false
      t.datetime :effective_from, null: false
      t.string :catalog_title, null: false
      t.string :catalog_sku
      t.string :created_by, null: false
      t.datetime :created_at, null: false
    end
    add_index :bulk_recipes, %i[tenant_id source source_variant_id version], unique: true, name: 'idx_bulk_recipe_version'
    add_index :bulk_recipes, %i[tenant_id source source_variant_id effective_from], name: 'idx_bulk_recipe_effective'
    add_index :bulk_recipes, %i[tenant_id bulk_material_id], name: 'idx_bulk_recipe_material'
    add_check_constraint :bulk_recipes, "source = 'shopify' AND version > 0 AND mg_per_unit > 0", name: 'bulk_recipe_positive'

    create_table :bulk_consumptions do |t|
      t.string :tenant_id, null: false
      t.string :source, null: false
      t.string :source_order_id, null: false
      t.string :source_line_id, null: false
      t.string :source_variant_id, null: false
      t.string :order_number
      t.bigint :quantity, null: false
      t.references :bulk_recipe, null: false, foreign_key: true, index: false
      t.references :bulk_lot, null: false, foreign_key: true, index: false
      t.references :bulk_movement, null: false, foreign_key: true, index: false
      t.bigint :mg_per_unit, null: false
      t.bigint :consumed_mg, null: false
      t.string :source_fingerprint, null: false
      t.string :request_fingerprint, null: false
      t.string :request_token, null: false
      t.string :created_by, null: false
      t.datetime :created_at, null: false
    end
    add_index :bulk_consumptions, %i[tenant_id source source_order_id source_line_id], unique: true, name: 'idx_bulk_consumption_source_line'
    add_index :bulk_consumptions, %i[tenant_id request_token], unique: true, name: 'idx_bulk_consumption_request'
    add_index :bulk_consumptions, :bulk_movement_id, unique: true
    add_index :bulk_consumptions, %i[tenant_id bulk_lot_id created_at], name: 'idx_bulk_consumption_lot'
    add_index :bulk_consumptions, %i[tenant_id bulk_recipe_id], name: 'idx_bulk_consumption_recipe'
    add_check_constraint :bulk_consumptions, "source = 'shopify' AND quantity > 0 AND mg_per_unit > 0 AND consumed_mg > 0", name: 'bulk_consumption_positive'
  end
end
