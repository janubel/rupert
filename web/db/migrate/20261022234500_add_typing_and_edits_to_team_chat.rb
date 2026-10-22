# frozen_string_literal: true

# "Sam is typing…" (a heartbeat on the membership) and edited messages.
class AddTypingAndEditsToTeamChat < ActiveRecord::Migration[8.1]
  def change
    add_column :chat_memberships, :typing_at, :datetime
    add_column :chat_messages, :edited_at, :datetime
  end
end
