# frozen_string_literal: true

# "Recently active" in team chat: when someone last used Rupert, and whether
# they chose to hide it (nil = shown; a workspace rule can override either way).
class AddPresenceToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :last_active_at, :datetime
    add_column :users, :presence_hidden, :boolean
  end
end
