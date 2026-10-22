# frozen_string_literal: true

# Thumbs up / down on assistant replies in team chat, one per person per reply,
# with the model and agent copied from the reply so scores per model survive
# later changes to the reply.
class CreateChatRatings < ActiveRecord::Migration[8.1]
  def change
    create_table :chat_ratings do |t|
      t.string :tenant_id, null: false
      t.references :message, null: false, foreign_key: { to_table: :chat_messages }
      t.bigint :user_id, null: false
      t.integer :value, null: false
      t.string :agent, null: false, default: 'rupert'
      t.string :model
      t.string :engine
      t.timestamps
      t.index %i[message_id user_id], unique: true
      t.index %i[tenant_id model]
    end
  end
end
