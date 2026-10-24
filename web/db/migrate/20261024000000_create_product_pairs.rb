# frozen_string_literal: true

# A person's decision that a Shopify variant and a C-Trax item are the same product (paired) or are not
# (not_same). Stored in Rupert only; nothing is written to Shopify or C-Trax.
class CreateProductPairs < ActiveRecord::Migration[8.1]
  def change
    create_table :product_pairs do |t|
      t.string :tenant_id, null: false
      t.string :shopify_variant_id, null: false
      t.string :ctrax_location_id, null: false
      t.string :ctrax_record_id, null: false
      t.string :decision, null: false
      t.string :shopify_signature
      t.string :ctrax_signature
      t.string :note, limit: 500
      t.bigint :decided_by_id
      t.timestamps
    end
    add_index :product_pairs, %i[tenant_id ctrax_location_id shopify_variant_id ctrax_record_id], unique: true, name: 'idx_product_pairs_scope'
  end
end
