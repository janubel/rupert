# frozen_string_literal: true

class CreateChatRuns < ActiveRecord::Migration[8.1]
  def change
    create_table :chat_runs do |t|
      t.string :tenant_id, null: false
      t.references :message, null: false, index: { unique: true }, foreign_key: { to_table: :chat_messages, on_delete: :cascade }
      t.string :state, null: false, default: 'queued'
      t.string :owner_token
      t.datetime :lease_until
      t.datetime :heartbeat_at
      t.datetime :deadline_at, null: false
      t.datetime :dispatched_at
      t.integer :attempts, null: false, default: 0
      t.integer :steps, null: false, default: 0
      t.json :transcript, null: false, default: []
      t.json :tool_results, null: false, default: []
      t.json :configuration, null: false, default: {}
      t.timestamps
      t.index [:state, :lease_until]
      t.index [:state, :deadline_at]
      t.index :tenant_id
    end
  end
end
