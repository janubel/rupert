# frozen_string_literal: true

class CreateCustomerManagement < ActiveRecord::Migration[8.1]
  def change
    add_column :customers, :crm_status, :string, null: false, default: 'customer'
    add_column :customers, :tags, :string
    add_column :customers, :preferred_name, :string
    add_column :customers, :owner_id, :bigint
    add_index :customers, [:tenant_id, :crm_status]
    add_index :customers, [:tenant_id, :owner_id]
    create_table :customer_interactions do |t|
      t.string :tenant_id, null: false
      t.references :customer, null: false, foreign_key: true
      t.bigint :author_id, null: false
      t.string :kind, null: false, default: 'note'
      t.text :body, null: false
      t.timestamps
      t.index [:tenant_id, :customer_id, :created_at], name: 'idx_customer_interactions_timeline'
    end
    add_foreign_key :customer_interactions, :tenants
    create_table :customer_follow_ups do |t|
      t.string :tenant_id, null: false
      t.references :customer, null: false, foreign_key: true
      t.bigint :author_id, null: false
      t.bigint :owner_id
      t.string :title, null: false
      t.date :due_on, null: false
      t.datetime :completed_at
      t.timestamps
      t.index [:tenant_id, :completed_at, :due_on], name: 'idx_customer_follow_ups_due'
    end
    add_foreign_key :customer_follow_ups, :tenants
  end
end
