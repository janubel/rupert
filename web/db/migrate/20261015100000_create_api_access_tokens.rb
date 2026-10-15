# frozen_string_literal: true

class CreateApiAccessTokens < ActiveRecord::Migration[8.1]
  def change
    create_table :api_access_tokens, id: :string do |t|
      t.string :tenant_id, null: false
      t.references :user, null: false, foreign_key: { on_delete: :cascade }
      t.string :name, null: false
      t.string :token_digest, null: false
      t.string :token_hint, null: false
      t.text :scopes, null: false
      t.datetime :expires_at
      t.datetime :revoked_at
      t.datetime :created_at, null: false, default: -> { 'CURRENT_TIMESTAMP' }
    end
    add_index :api_access_tokens, :token_digest, unique: true
    add_index :api_access_tokens, %i[tenant_id created_at], name: 'idx_api_tokens_tenant_created'
    add_foreign_key :api_access_tokens, :tenants, on_delete: :cascade
  end
end
