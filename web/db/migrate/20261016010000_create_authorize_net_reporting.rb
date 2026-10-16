# frozen_string_literal: true

class CreateAuthorizeNetReporting < ActiveRecord::Migration[8.1]
  def change
    add_column :pos_connections, :reporting_auth_mode, :string, default: 'api_key', null: false
    add_column :pos_connections, :reporting_enabled, :boolean, default: false, null: false
    add_column :pos_connections, :last_reported_at, :datetime
    add_column :pos_connections, :last_report_status, :string
    add_column :pos_connections, :last_report_message, :string

    create_table :authorize_net_batches do |t|
      t.references :tenant, type: :string, null: false, foreign_key: true
      t.string :environment, null: false
      t.string :gateway_id, null: false
      t.string :source_batch_id, null: false
      t.datetime :settled_at
      t.string :settlement_state, null: false
      t.string :payment_method
      t.json :statistics, null: false, default: []
      t.datetime :observed_at, null: false
      t.timestamps
    end
    add_index :authorize_net_batches, [:tenant_id, :environment, :gateway_id, :source_batch_id], unique: true, name: 'idx_anet_batch_source'

    create_table :authorize_net_transactions do |t|
      t.references :tenant, type: :string, null: false, foreign_key: true
      t.string :environment, null: false
      t.string :gateway_id, null: false
      t.string :source_transaction_id, null: false
      t.string :reference_transaction_id
      t.string :source_batch_id
      t.string :transaction_type, null: false
      t.string :payment_status, null: false
      t.datetime :submitted_at, null: false
      t.datetime :settled_at
      t.string :settlement_state
      t.string :currency
      t.decimal :authorized_amount, precision: 19, scale: 4, null: false
      t.decimal :settled_amount, precision: 19, scale: 4, null: false
      t.decimal :tip_amount, precision: 19, scale: 4
      t.decimal :surcharge_amount, precision: 19, scale: 4
      t.string :market_type
      t.string :product
      t.datetime :observed_at, null: false
      t.json :status_history, null: false, default: []
      t.timestamps
    end
    add_index :authorize_net_transactions, [:tenant_id, :environment, :gateway_id, :source_transaction_id], unique: true, name: 'idx_anet_transaction_source'
  end
end
