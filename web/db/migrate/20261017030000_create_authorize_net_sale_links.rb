# frozen_string_literal: true

class CreateAuthorizeNetSaleLinks < ActiveRecord::Migration[8.1]
  def change
    add_column :authorize_net_transactions, :invoice_number, :text
    create_table :authorize_net_sale_links do |t|
      t.references :tenant, type: :string, null: false, foreign_key: true
      t.references :authorize_net_transaction, null: false, foreign_key: true, index: { name: 'idx_anet_link_transaction' }
      t.references :order, null: false, foreign_key: true
      t.references :reviewed_by, null: false, foreign_key: { to_table: :users }
      t.text :evidence_note, null: false
      t.datetime :revoked_at
      t.references :revoked_by, foreign_key: { to_table: :users }
      t.timestamps
    end
    add_index :authorize_net_sale_links, [:tenant_id, :order_id], unique: true, where: 'revoked_at IS NULL', name: 'idx_anet_link_active_order'
    add_index :authorize_net_sale_links, [:tenant_id, :authorize_net_transaction_id], unique: true, where: 'revoked_at IS NULL', name: 'idx_anet_link_active_payment'
  end
end
