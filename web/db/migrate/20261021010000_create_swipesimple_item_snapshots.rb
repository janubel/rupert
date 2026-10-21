# frozen_string_literal: true

class CreateSwipesimpleItemSnapshots < ActiveRecord::Migration[8.1]
  def change
    create_table :swipesimple_item_snapshots do |t|
      t.string :tenant_id, null: false
      t.string :merchant_account, null: false
      t.text :records_json, null: false
      t.string :source_filename
      t.string :sha256, null: false
      t.integer :row_count, null: false
      t.datetime :captured_at, null: false
      t.bigint :imported_by_id
      t.timestamps
    end
    add_index :swipesimple_item_snapshots, %i[tenant_id merchant_account], unique: true, name: 'idx_swipesimple_items_account'
  end
end
