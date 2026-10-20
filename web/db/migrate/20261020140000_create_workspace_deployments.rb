# frozen_string_literal: true

class CreateWorkspaceDeployments < ActiveRecord::Migration[8.1]
  def change
    create_table :workspace_deployments do |t|
      t.string :tenant_id, null: false
      t.references :owner, null: false, foreign_key: {to_table: :users}
      t.string :instance_id, null: false
      t.string :hostname, null: false
      t.text :instance_secret, null: false
      t.string :status, null: false, default: 'requested'
      t.string :phase, null: false, default: 'queued'
      t.integer :attempts, null: false, default: 0
      t.string :lease_digest
      t.datetime :lease_expires_at
      t.string :failure_code
      t.datetime :ready_at
      t.timestamps
    end
    add_foreign_key :workspace_deployments, :tenants
    add_index :workspace_deployments, :tenant_id, unique: true
    add_index :workspace_deployments, :instance_id, unique: true
    add_index :workspace_deployments, :hostname, unique: true
    add_index :workspace_deployments, [:status, :id]
    create_table :workspace_handoffs do |t|
      t.references :workspace_deployment, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.references :support_access_grant, foreign_key: true
      t.string :token_digest, null: false
      t.datetime :expires_at, null: false
      t.datetime :consumed_at
      t.timestamps
    end
    add_index :workspace_handoffs, :token_digest, unique: true
  end
end
