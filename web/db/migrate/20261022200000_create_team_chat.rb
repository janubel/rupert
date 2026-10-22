# frozen_string_literal: true

# Team chat: rooms, who is in them and their messages, stored in Rupert itself
# (no relay, no sync). The @rupert assistant writes into the same messages table
# (author_kind 'assistant'), so a reply is just another row the page polls for.
class CreateTeamChat < ActiveRecord::Migration[8.1]
  def change
    create_table :chat_rooms do |t|
      t.string :tenant_id, null: false
      t.string :name, null: false
      t.string :slug, null: false
      t.string :topic
      # channel: a shared room. direct: one person and Rupert.
      t.string :kind, null: false, default: 'channel'
      # When @rupert answers: mentions, all (every message) or off.
      t.string :assistant_mode, null: false, default: 'mentions'
      t.bigint :created_by_id
      t.datetime :last_message_at
      t.datetime :archived_at
      t.timestamps
      t.index %i[tenant_id slug], unique: true
      t.index %i[tenant_id kind created_by_id]
    end

    create_table :chat_memberships do |t|
      t.string :tenant_id, null: false
      t.references :room, null: false, foreign_key: { to_table: :chat_rooms }
      t.bigint :user_id, null: false
      t.bigint :last_read_message_id, null: false, default: 0
      t.timestamps
      t.index %i[room_id user_id], unique: true
      t.index %i[tenant_id user_id]
    end

    create_table :chat_messages do |t|
      t.string :tenant_id, null: false
      t.references :room, null: false, foreign_key: { to_table: :chat_rooms }
      t.bigint :user_id
      # person, assistant or system (Rupert's own notices, e.g. an approved action).
      t.string :author_kind, null: false, default: 'person'
      t.text :body, null: false, default: ''
      t.bigint :parent_id
      # done, pending (the assistant is still writing) or failed.
      t.string :status, null: false, default: 'done'
      # What the assistant is doing right now, e.g. "Checking sales summary".
      t.string :activity
      # Changes the assistant proposed; each needs a person to approve it.
      t.text :actions
      # People @mentioned (user ids, checked against the body when posted).
      t.text :mentions
      # Provider, model, tokens, tools used and who asked. Never message text.
      t.text :meta
      t.datetime :deleted_at
      t.timestamps
      t.index %i[room_id id]
      t.index %i[room_id parent_id id]
      t.index %i[room_id status]
    end

    # Images and files posted with a message. Kept in the database (like
    # feedback screenshots) so backups carry them; the type is judged from the
    # bytes, and they are only served to people who can open the room.
    create_table :chat_attachments do |t|
      t.string :tenant_id, null: false
      t.references :room, null: false, foreign_key: { to_table: :chat_rooms }
      t.references :message, null: false, foreign_key: { to_table: :chat_messages }
      t.string :filename, null: false
      t.string :content_type, null: false
      t.integer :byte_size, null: false, default: 0
      t.binary :data, null: false
      t.timestamps
    end

    create_table :chat_reactions do |t|
      t.string :tenant_id, null: false
      t.references :message, null: false, foreign_key: { to_table: :chat_messages }
      t.bigint :user_id, null: false
      t.string :emoji, null: false
      t.timestamps
      t.index %i[message_id user_id emoji], unique: true
    end
  end
end
