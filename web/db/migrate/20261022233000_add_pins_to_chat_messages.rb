# frozen_string_literal: true

# Pinned messages: the room shows its latest pin as a banner, with the rest a click away.
class AddPinsToChatMessages < ActiveRecord::Migration[8.1]
  def change
    add_column :chat_messages, :pinned_at, :datetime
    add_column :chat_messages, :pinned_by_id, :bigint
    add_index :chat_messages, %i[room_id pinned_at]
  end
end
