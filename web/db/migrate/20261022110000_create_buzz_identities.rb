# frozen_string_literal: true

# Links a Buzz (Nostr) public key to the Rupert person who owns it, so the
# @rupert agent can answer that person as themselves. A row starts as a one-use
# code made in Rupert, becomes pending when the person sends the code to the
# agent in a direct message, and active only when they confirm it back in
# Rupert. Only a hash of the code is kept. Holds no chat text.
class CreateBuzzIdentities < ActiveRecord::Migration[8.1]
  def change
    create_table :buzz_identities do |t|
      t.string :tenant_id, null: false
      t.bigint :user_id, null: false
      t.string :status, null: false, default: 'code'
      t.string :pubkey
      t.string :code_digest
      t.datetime :code_expires_at
      t.datetime :claimed_at
      t.datetime :linked_at
      t.datetime :last_used_at
      t.datetime :disclosed_at
      t.datetime :revoked_at
      t.timestamps
      t.index %i[tenant_id user_id], name: 'idx_buzz_identities_user'
      t.index %i[tenant_id code_digest], name: 'idx_buzz_identities_code'
      t.index %i[tenant_id pubkey], unique: true, where: "pubkey IS NOT NULL AND status IN ('pending', 'active')", name: 'idx_buzz_identities_live_pubkey'
    end
  end
end
