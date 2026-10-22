# frozen_string_literal: true

# Saved team chat test-battery runs, so the Model scores page can show every run and
# the battery can skip a model already tested on the same question set and Rupert version.
class CreateChatBatteryRuns < ActiveRecord::Migration[8.1]
  def change
    create_table :chat_battery_runs do |t|
      t.string :tenant_id, null: false
      t.string :run_key, null: false
      t.string :set_name, null: false, default: 'default'
      t.string :agent
      t.string :model
      t.string :engine
      t.string :revision
      t.string :status, null: false, default: 'running'
      t.integer :questions, null: false, default: 0
      t.integer :answered, null: false, default: 0
      t.decimal :avg_grade, precision: 3, scale: 2
      t.float :avg_seconds
      t.float :max_seconds
      t.integer :flagged, null: false, default: 0
      t.text :by_cadence
      t.text :results
      t.integer :room_id
      t.datetime :started_at
      t.datetime :finished_at
      t.timestamps
    end
    add_index :chat_battery_runs, :run_key, unique: true
    add_index :chat_battery_runs, %i[tenant_id started_at]
  end
end
