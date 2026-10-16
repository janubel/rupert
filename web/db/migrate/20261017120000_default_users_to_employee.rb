# frozen_string_literal: true

class DefaultUsersToEmployee < ActiveRecord::Migration[8.1]
  # SQLite must disable foreign keys before its table-rebuild transaction.
  # An outer migration transaction prevents PRAGMA foreign_keys = OFF and
  # cascading dependent rows can otherwise be deleted when users is rebuilt.
  disable_ddl_transaction!

  def change
    change_column_default :users, :role, from: 'admin', to: 'employee'
  end
end
