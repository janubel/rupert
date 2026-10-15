# frozen_string_literal: true

class CreateWorkspaceSignups < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :referral_domain, :string
    add_index :users, :referral_domain
    add_column :tenants, :referral_domain, :string
    add_index :tenants, :referral_domain
    create_table :workspace_signups do |t|
      t.string :google_subject, null: false
      t.string :applicant_name, null: false
      t.string :email, null: false
      t.string :domain, null: false
      t.string :workspace_name, null: false
      t.string :requested_subdomain, null: false
      t.string :referral_domain, null: false, default: 'herbalhealershcb.com'
      t.string :status, null: false, default: 'pending'
      t.references :reviewer, foreign_key: { to_table: :users, on_delete: :nullify }
      t.datetime :reviewed_at
      t.string :tenant_id
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    add_foreign_key :workspace_signups, :tenants
    add_index :workspace_signups, :email, unique: true
    add_index :workspace_signups, :google_subject, unique: true
    add_index :workspace_signups, %i[status created_at id], name: 'idx_workspace_signups_queue'
    add_index :workspace_signups, :domain
    add_index :workspace_signups, :domain, unique: true, where: "status = 'approved'", name: 'idx_workspace_signups_approved_domain'
    create_table :workspace_signup_events do |t|
      t.references :workspace_signup, null: false, foreign_key: true
      t.references :actor, foreign_key: { to_table: :users, on_delete: :nullify }
      t.string :action, null: false
      t.text :payload_json, null: false
      t.datetime :created_at, null: false
    end
    add_index :workspace_signup_events, %i[created_at id]
  end
end
