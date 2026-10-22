# frozen_string_literal: true

# One Buzz (Nostr) identity per Rupert person, so the WebUI Buzz client posts and
# shows typing as that person instead of through the Rupert agent's key. The
# private key is encrypted at rest (Active Record encryption) and never shown.
class CreateBuzzPersonKeys < ActiveRecord::Migration[8.1]
  def change
    create_table :buzz_person_keys do |t|
      t.string :tenant_id, null: false
      t.references :user, null: false, foreign_key: { on_delete: :cascade }
      t.string :pubkey, limit: 64, null: false
      t.text :private_key, null: false
      t.datetime :profile_published_at
      t.timestamps
    end
    add_index :buzz_person_keys, %i[tenant_id user_id], unique: true, name: 'idx_buzz_person_keys_user'
    add_index :buzz_person_keys, :pubkey, unique: true, name: 'idx_buzz_person_keys_pubkey'
  end
end
