# frozen_string_literal: true

class CreateInfluencerCms < ActiveRecord::Migration[8.1]
  def change
    create_table :marketing_influencers do |t|
      t.string :tenant_id, null: false
      t.string :name, null: false
      t.string :platform
      t.string :handle
      t.string :profile_url
      t.text :topics
      t.string :stage, null: false, default: 'prospect'
      t.bigint :owner_id
      t.datetime :next_follow_up_at
      t.text :notes
      t.text :contact_email
      t.text :shipping_details
      t.text :private_notes
      t.integer :lock_version, null: false, default: 0
      t.timestamps
      t.index [:tenant_id, :stage, :next_follow_up_at], name: 'marketing_influencer_queue'
      t.index [:tenant_id, :profile_url], unique: true
    end
    add_foreign_key :marketing_influencers, :users, column: :owner_id
    create_table :marketing_engagements do |t|
      t.string :tenant_id, null: false
      t.references :influencer, null: false, foreign_key: { to_table: :marketing_influencers }
      t.references :campaign, null: false, foreign_key: { to_table: :marketing_campaigns }
      t.string :title, null: false
      t.string :status, null: false, default: 'draft'
      t.text :deliverables
      t.datetime :due_at
      t.string :destination_url, null: false
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    create_table :marketing_interactions do |t|
      t.string :tenant_id, null: false
      t.references :influencer, null: false, foreign_key: { to_table: :marketing_influencers }
      t.bigint :actor_id, null: false
      t.string :kind, null: false
      t.text :body, null: false
      t.datetime :occurred_at, null: false
      t.timestamps
    end
    add_foreign_key :marketing_interactions, :users, column: :actor_id
    create_table :marketing_product_gifts do |t|
      t.string :tenant_id, null: false
      t.references :engagement, null: false, foreign_key: { to_table: :marketing_engagements }
      t.string :status, null: false, default: 'proposed'
      t.string :currency, null: false, default: 'USD'
      t.integer :shipping_cost_cents
      t.text :note
      t.text :shipping_details
      t.datetime :recipient_confirmed_at
      t.string :carrier
      t.text :tracking_number
      t.text :tracking_url
      t.datetime :shipped_at
      t.datetime :delivered_at
      t.datetime :returned_at
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    create_table :marketing_product_gift_items do |t|
      t.string :tenant_id, null: false
      t.references :product_gift, null: false, foreign_key: { to_table: :marketing_product_gifts }
      t.string :source_variant_id, null: false
      t.string :product_name, null: false
      t.string :sku
      t.integer :quantity, null: false
      t.integer :unit_cost_cents
      t.timestamps
      t.index [:product_gift_id, :source_variant_id], unique: true, name: 'marketing_gift_variant'
    end
    create_table :marketing_documents do |t|
      t.string :tenant_id, null: false
      t.references :engagement, null: false, foreign_key: { to_table: :marketing_engagements }
      t.string :title, null: false
      t.string :kind, null: false
      t.string :visibility, null: false, default: 'internal'
      t.string :status, null: false, default: 'draft'
      t.bigint :reviewed_by_id
      t.datetime :reviewed_at
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    add_foreign_key :marketing_documents, :users, column: :reviewed_by_id
    create_table :marketing_document_revisions do |t|
      t.string :tenant_id, null: false
      t.references :document, null: false, foreign_key: { to_table: :marketing_documents }
      t.bigint :actor_id, null: false
      t.integer :number, null: false
      t.string :title, null: false
      t.string :kind, null: false
      t.text :body, null: false
      t.text :source_url
      t.timestamps
      t.index [:document_id, :number], unique: true
    end
    add_foreign_key :marketing_document_revisions, :users, column: :actor_id
    create_table :marketing_cms_events do |t|
      t.string :tenant_id, null: false
      t.bigint :actor_id, null: false
      t.string :subject_type, null: false
      t.bigint :subject_id, null: false
      t.string :action, null: false
      t.text :payload_json, null: false
      t.timestamps
      t.index [:tenant_id, :subject_type, :subject_id], name: 'marketing_cms_history'
    end
    add_foreign_key :marketing_cms_events, :users, column: :actor_id
    %i[influencers engagements interactions product_gifts product_gift_items documents document_revisions cms_events].each do |name|
      add_index "marketing_#{name}", :tenant_id
      add_foreign_key "marketing_#{name}", :tenants
    end
    change_column_null :marketing_offers, :community_id, true
    add_reference :marketing_offers, :engagement, foreign_key: { to_table: :marketing_engagements }
    add_check_constraint :marketing_offers, '(community_id IS NOT NULL AND engagement_id IS NULL) OR (community_id IS NULL AND engagement_id IS NOT NULL)', name: 'marketing_offer_recipient'
  end
end
