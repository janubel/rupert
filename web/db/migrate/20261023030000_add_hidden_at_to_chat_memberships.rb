# frozen_string_literal: true

# A person can hide a room from their own room list (it moves under "Hidden rooms").
class AddHiddenAtToChatMemberships < ActiveRecord::Migration[8.1]
  def change
    add_column :chat_memberships, :hidden_at, :datetime
  end
end
