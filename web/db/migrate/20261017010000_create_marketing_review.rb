# frozen_string_literal: true

class CreateMarketingReview < ActiveRecord::Migration[8.1]
  def change
    create_table :marketing_campaigns do |t|
      t.string :tenant_id, null: false
      t.string :name, null: false
      t.string :storefront_url, null: false
      t.text :topics, null: false
      t.integer :lock_version, default: 0, null: false
      t.timestamps
    end
    create_table :marketing_communities do |t|
      t.string :tenant_id, null: false
      t.references :campaign, null: false, foreign_key: { to_table: :marketing_campaigns }
      t.string :name, null: false
      t.string :url, null: false
      t.text :include_terms, null: false
      t.text :exclude_terms
      t.text :promotion_rules, null: false
      t.string :rules_url, null: false
      t.datetime :rules_checked_at
      t.integer :lock_version, default: 0, null: false
      t.timestamps
    end
    create_table :marketing_offers do |t|
      t.string :tenant_id, null: false
      t.references :community, null: false, foreign_key: { to_table: :marketing_communities }
      t.string :merchant_host, null: false
      t.string :code, null: false
      t.text :terms, null: false
      t.string :destination_url, null: false
      t.datetime :starts_at, null: false
      t.datetime :ends_at, null: false
      t.string :evidence_url
      t.datetime :verified_at
      t.bigint :verified_by_id
      t.integer :lock_version, default: 0, null: false
      t.timestamps
    end
    add_index :marketing_offers, [:tenant_id, :merchant_host, :code], unique: true, name: 'marketing_offer_codes'
    create_table :marketing_threads do |t|
      t.string :tenant_id, null: false
      t.references :community, null: false, foreign_key: { to_table: :marketing_communities }
      t.string :url, null: false
      t.string :title, null: false
      t.text :excerpt, null: false
      t.string :status, default: 'new', null: false
      t.string :availability, default: 'open', null: false
      t.text :triage_note
      t.datetime :checked_at
      t.datetime :snoozed_until
      t.integer :lock_version, default: 0, null: false
      t.timestamps
    end
    add_index :marketing_threads, [:tenant_id, :url], unique: true
    create_table :marketing_replies do |t|
      t.string :tenant_id, null: false
      t.references :thread, null: false, foreign_key: { to_table: :marketing_threads }, index: { unique: true }
      t.references :offer, null: false, foreign_key: { to_table: :marketing_offers }
      t.text :body, null: false
      t.string :affiliation, null: false
      t.string :status, default: 'draft', null: false
      t.text :snapshot_json
      t.string :snapshot_digest
      t.string :published_url
      t.datetime :published_at
      t.integer :lock_version, default: 0, null: false
      t.timestamps
    end
    create_table :marketing_review_events do |t|
      t.string :tenant_id, null: false
      t.references :reply, null: false, foreign_key: { to_table: :marketing_replies }
      t.bigint :actor_id, null: false
      t.string :action, null: false
      t.text :payload_json, null: false
      t.timestamps
    end
    %i[campaigns communities offers threads replies review_events].each do |name|
      add_foreign_key "marketing_#{name}", :tenants
      add_index "marketing_#{name}", :tenant_id
    end
    add_foreign_key :marketing_offers, :users, column: :verified_by_id
    add_foreign_key :marketing_review_events, :users, column: :actor_id
    add_index :marketing_threads, [:tenant_id, :status, :created_at]
    add_index :marketing_replies, [:tenant_id, :status, :updated_at]
  end
end
