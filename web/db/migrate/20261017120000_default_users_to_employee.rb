# frozen_string_literal: true

class DefaultUsersToEmployee < ActiveRecord::Migration[8.1]
  def change
    change_column_default :users, :role, from: 'admin', to: 'employee'
  end
end
