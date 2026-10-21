# frozen_string_literal: true

class CreateCtraxDailyReconciliation < ActiveRecord::Migration[8.0]
  def change
    create_table :ctrax_days do |t|
      t.references :tenant, type: :string, null: false, foreign_key: true
      t.string :location_id, null: false
      t.string :api_origin, null: false
      t.string :store_id, null: false
      t.date :business_date, null: false
      t.string :timezone, null: false
      t.string :currency, null: false, default: 'USD'
      t.text :orders_json, null: false
      t.text :sessions_json, null: false
      t.text :controls_json, null: false
      t.string :source_digest, null: false
      t.datetime :captured_at, null: false
      t.references :reviewed_by, foreign_key: { to_table: :users }
      t.string :reviewed_digest
      t.datetime :reviewed_at
      t.string :review_note, limit: 1000
      t.timestamps
    end
    add_index :ctrax_days, %i[tenant_id location_id business_date], unique: true
    add_foreign_key :ctrax_days, 'Location', column: :location_id, on_delete: :cascade
    create_table :ctrax_image_links do |t|
      t.references :tenant, type: :string, null: false, foreign_key: true
      t.string :location_id, null: false
      t.string :variant_id, null: false
      t.string :shopify_product_id, null: false
      t.timestamps
    end
    add_index :ctrax_image_links, %i[tenant_id location_id variant_id], unique: true
    add_foreign_key :ctrax_image_links, 'Location', column: :location_id, on_delete: :cascade
    add_foreign_key :ctrax_image_links, 'ShopifyProduct', column: :shopify_product_id, on_delete: :cascade
    create_table :pos_display_sessions do |t|
      t.references :tenant, type: :string, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.string :location_id, null: false
      t.text :display_token, null: false
      t.string :token_digest, null: false
      t.text :draft_json, null: false, default: '{}'
      t.string :draft_digest
      t.integer :cart_revision, null: false, default: 0
      t.integer :confirmed_revision
      t.integer :chosen_tip_cents
      t.boolean :demo, null: false, default: false
      t.datetime :expires_at, null: false
      t.datetime :closed_at
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    add_index :pos_display_sessions, :token_digest, unique: true
    add_foreign_key :pos_display_sessions, 'Location', column: :location_id, on_delete: :cascade
    add_foreign_key :pos_checkouts, :pos_display_sessions
  end
end
