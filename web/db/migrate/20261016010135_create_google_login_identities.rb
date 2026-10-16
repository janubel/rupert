# frozen_string_literal: true

class CreateGoogleLoginIdentities < ActiveRecord::Migration[8.1]
  def change
    create_table :google_login_identities do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }
      t.string :email, null: false
      t.string :google_subject
      t.timestamps
    end
    add_index :google_login_identities, :email, unique: true
    add_index :google_login_identities, :google_subject, unique: true
  end
end
