# frozen_string_literal: true

# A workspace's own test questions (TeamChat::BatteryQuestion): new ones, edited copies of built-in ones (same
# question id) and removed built-in ones. The built-in sets stay in config/team_chat/battery*.yml.
class CreateChatBatteryQuestions < ActiveRecord::Migration[8.1]
  def change
    create_table :chat_battery_questions do |t|
      t.string :tenant_id, null: false
      t.string :set_name, null: false
      t.string :question_id, null: false
      t.string :status, null: false, default: 'active'
      t.text :question
      t.text :expect
      t.string :cadence
      t.string :area
      t.text :checks_json
      t.text :needs_json
      t.bigint :updated_by_id
      t.timestamps
    end
    add_index :chat_battery_questions, %i[tenant_id set_name question_id], unique: true, name: 'idx_chat_battery_questions_scope'
  end
end
