# frozen_string_literal: true

class CreateChatTelemetry < ActiveRecord::Migration[8.1]
  def change
    create_table :chat_telemetry do |t|
      t.string :tenant_id, null: false
      t.references :run, null: false, foreign_key: { to_table: :chat_runs, on_delete: :cascade }
      t.string :claim_token, null: false
      t.string :kind, null: false
      t.string :stage
      t.string :outcome, null: false, default: 'running'
      t.datetime :started_at, null: false
      t.datetime :finished_at
      t.integer :duration_ms
      t.json :facts, null: false, default: {}
      t.index [:tenant_id, :started_at]
    end
  end
end
