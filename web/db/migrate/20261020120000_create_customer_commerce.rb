# frozen_string_literal: true

class CreateCustomerCommerce < ActiveRecord::Migration[8.1]
  def change
    create_table :customer_subscriptions do |t|
      t.string :tenant_id, null: false
      t.string :stripe_customer_id
      t.string :stripe_subscription_id
      t.string :checkout_token
      t.string :checkout_session_id
      t.text :checkout_url
      t.datetime :checkout_expires_at
      t.string :status, null: false, default: 'free'
      t.string :plan, null: false, default: 'free'
      t.string :referral_code
      t.datetime :commitment_accepted_at
      t.string :terms_version
      t.datetime :commitment_ends_at
      t.datetime :last_synced_at
      t.timestamps
    end
    add_foreign_key :customer_subscriptions, :tenants
    add_index :customer_subscriptions, :tenant_id, unique: true
    add_index :customer_subscriptions, :stripe_subscription_id, unique: true
    create_table :customer_referrals do |t|
      t.string :tenant_id, null: false
      t.string :code, null: false
      t.boolean :active, null: false, default: true
      t.timestamps
    end
    add_foreign_key :customer_referrals, :tenants
    add_index :customer_referrals, :code, unique: true
    add_index :customer_referrals, :tenant_id, unique: true
    create_table :support_access_grants do |t|
      t.string :tenant_id, null: false
      t.references :granted_by, null: false, foreign_key: {to_table: :users}
      t.references :support_user, null: false, foreign_key: {to_table: :users}
      t.text :reason, null: false
      t.datetime :expires_at, null: false
      t.datetime :revoked_at
      t.timestamps
    end
    add_foreign_key :support_access_grants, :tenants
    add_index :support_access_grants, [:tenant_id, :support_user_id]
    create_table :support_access_events do |t|
      t.string :tenant_id, null: false
      t.references :actor, null: false, foreign_key: {to_table: :users}
      t.references :support_access_grant, foreign_key: true
      t.string :action, null: false
      t.string :resource
      t.datetime :created_at, null: false
    end
    add_foreign_key :support_access_events, :tenants
  end
end
