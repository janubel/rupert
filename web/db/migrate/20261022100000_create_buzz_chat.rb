# frozen_string_literal: true

# The Team chat tab on the Buzz page. Rupert keeps a short-lived copy of the
# channel's recent messages (and the names of the people who wrote them) so the
# page loads fast and still shows history while the relay is briefly out of
# reach. The relay stays the source of truth; rows are deleted after the
# retention window. Message text is untrusted and capped before it is stored.
class CreateBuzzChat < ActiveRecord::Migration[8.1]
  def change
    create_table :buzz_messages do |t|
      t.string :tenant_id, null: false
      t.string :event_id, null: false, limit: 64
      t.string :pubkey, null: false, limit: 64
      t.integer :kind, null: false
      t.string :channel, null: false
      t.text :content, null: false, default: ''
      t.string :reply_to, limit: 64
      t.string :client, limit: 40
      t.bigint :rupert_user_id
      t.bigint :posted_at, null: false
      t.timestamps
      t.index %i[tenant_id event_id], unique: true, name: 'idx_buzz_messages_event'
      t.index %i[tenant_id channel posted_at event_id], name: 'idx_buzz_messages_timeline'
    end

    create_table :buzz_profiles do |t|
      t.string :tenant_id, null: false
      t.string :pubkey, null: false, limit: 64
      t.string :name, limit: 100
      t.string :display_name, limit: 100
      t.datetime :fetched_at, null: false
      t.timestamps
      t.index %i[tenant_id pubkey], unique: true, name: 'idx_buzz_profiles_pubkey'
    end

    # One row per workspace: when Rupert last asked the relay, and how it went.
    # Doubles as the lock that keeps open pages from each starting a relay call.
    create_table :buzz_chat_states do |t|
      t.string :tenant_id, null: false
      t.datetime :last_attempt_at
      t.datetime :last_success_at
      t.string :last_error
      t.timestamps
      t.index :tenant_id, unique: true, name: 'idx_buzz_chat_states_tenant'
    end
  end
end
