# frozen_string_literal: true

# What a person marked done or snoozed in the Next thing to do bar (NextThings).
class CreateNextThingDismissals < ActiveRecord::Migration[8.1]
  def change
    create_table :next_thing_dismissals do |t|
      t.string :tenant_id, null: false
      t.bigint :user_id, null: false
      t.string :item_key, null: false
      t.string :fingerprint
      t.string :kind, null: false
      t.datetime :until_at
      t.timestamps
    end
    add_index :next_thing_dismissals, %i[tenant_id user_id item_key], unique: true, name: 'idx_next_thing_dismissals_scope'
  end
end
